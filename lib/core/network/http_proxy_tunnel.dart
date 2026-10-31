import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/network/tailnet_resolver.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens every connection of [client] (a `dart:io` client): through the
/// HTTP proxy at [proxy] when there is one, except connections to hosts
/// for which [bypass] is true, which are direct.
///
/// Every tunnel is opened here, in the client's connection factory, so the
/// client's `connectionTimeout` covers all of it: the connection to the
/// proxy, the `CONNECT` answer (Tor builds its circuit meanwhile) and, for
/// `https`, the TLS handshake with the server through the tunnel
/// ([connectSecureTunnel]). `dart:io`'s own proxy support (`findProxy`
/// answering `PROXY host:port`) would time only the connection to the
/// proxy, so a server that never answers through it would hang until the
/// request timed out, which a Mozhi request carrying text never fails over
/// from. Plain `http` (Tor `.onion` services, I2P sites) goes through a
/// `CONNECT` tunnel too ([connectTunnel]): `dart:io` would send
/// proxy-style requests (`GET http://…`), which Tor's HTTP tunnel port
/// refuses.
///
/// With a connection factory, `dart:io` uses the socket it returns as it
/// is (`findProxy` answers `DIRECT`) and adds no TLS of its own, so an
/// `https` connection is a [SecureSocket] secured here, with the URL's host
/// for SNI and the certificate check (the `Host` header always comes from
/// the URL).
///
/// Host names are resolved by the proxy, or without one by the system,
/// except Tailscale `.ts.net` names: [resolveHost] (default:
/// [TailnetResolver.instance]'s [TailnetResolver.resolve]) looks them up
/// first, so that [bypass] knows whether one leads to a tailnet (direct)
/// or is a public Funnel address (through the proxy). A name on the
/// tailnet ([TailnetHosts.isPrivate]) is connected to at the address that
/// lookup checked ([checkedAddress], default:
/// [TailnetResolver.instance]'s [TailnetResolver.connectAddress]), never
/// resolved again: another answer the second time (the network's resolver
/// once Tailscale is off) cannot move the connection elsewhere. Without
/// such an address the connection fails. [context] is the TLS trust of
/// `https` connections (default: the system's; tests).
///
/// [connectAddress], [connectRawAddress] and [secure] open those
/// connections to a checked address (tests).
void routeConnections(
  HttpClient client, {
  required bool Function(String host) bypass,
  ProxyAddress? proxy,
  SecurityContext? context,
  Future<void> Function(String host)? resolveHost,
  String? Function(String host)? checkedAddress,
  @visibleForTesting AddressConnect connectAddress = Socket.startConnect,
  @visibleForTesting
  RawAddressConnect connectRawAddress = startRawAddressConnect,
  @visibleForTesting SecureRawSocket secure = RawSecureSocket.secure,
}) {
  client
    // The connections are the factory's: dart:io connects "directly" to
    // what it returns and adds no TLS of its own.
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, _, _) async {
      final host = uri.host;
      await (resolveHost ?? TailnetResolver.instance.resolve)(host);
      final isSecure = uri.isScheme('https');
      if (TailnetHosts.isPrivate(host)) {
        final checked =
            (checkedAddress ?? TailnetResolver.instance.connectAddress)(host);
        final address = checked == null
            ? null
            : InternetAddress.tryParse(checked);
        if (address == null) {
          throw const SocketException(
            'No checked Tailscale address to connect to',
          );
        }
        return isSecure
            ? await connectSecureAddress(
                address,
                host,
                uri.port,
                context: context,
                connect: connectRawAddress,
                secure: secure,
              )
            : await connectAddress(address, uri.port);
      }
      if (proxy == null || bypass(host)) {
        return isSecure
            ? await SecureSocket.startConnect(host, uri.port, context: context)
            : await Socket.startConnect(host, uri.port);
      }
      return isSecure
          ? await connectSecureTunnel(proxy, host, uri.port, context: context)
          : await connectTunnel(proxy, host, uri.port);
    };
}

/// [routeConnections] with [proxy].
void routeThroughProxy(
  HttpClient client,
  ProxyAddress proxy, {
  required bool Function(String host) bypass,
  SecurityContext? context,
  Future<void> Function(String host)? resolveHost,
}) => routeConnections(
  client,
  proxy: proxy,
  bypass: bypass,
  context: context,
  resolveHost: resolveHost,
);

/// Starts a connection to [address]:[port] ([Socket.startConnect]).
typedef AddressConnect = Future<ConnectionTask<Socket>> Function(
  InternetAddress address,
  int port,
);

/// Starts a raw connection to [address]:[port] ([startRawAddressConnect]).
typedef RawAddressConnect =
    Future<({Future<RawSocket> socket, void Function() cancel})> Function(
      InternetAddress address,
      int port,
    );

/// [RawSocket.startConnect] to an address, as a [RawAddressConnect].
Future<({Future<RawSocket> socket, void Function() cancel})>
startRawAddressConnect(InternetAddress address, int port) async {
  final task = await RawSocket.startConnect(address, port);
  return (socket: task.socket, cancel: task.cancel);
}

/// Opens a connection to [address]:[port] and runs TLS with [host] on it:
/// [host] is the name sent for SNI and the one the server's certificate
/// must be valid for, whatever the address. The task's socket completes
/// once the handshake is done (a `HandshakeException` when TLS fails).
/// Cancelling the task closes the connection at once, also in the middle
/// of the handshake (as for [connectSecureTunnel]).
///
/// [connect] opens the connection and [secure] runs TLS on it (tests);
/// [context] is the TLS trust (default: the system's).
Future<ConnectionTask<Socket>> connectSecureAddress(
  InternetAddress address,
  String host,
  int port, {
  SecurityContext? context,
  @visibleForTesting RawAddressConnect connect = startRawAddressConnect,
  @visibleForTesting SecureRawSocket secure = RawSecureSocket.secure,
}) async => _securedConnection(
  await connect(address, port),
  (socket) async =>
      _SecureTunnelSocket(await secure(socket, host: host, context: context)),
);

/// The `host:port` of a `CONNECT` request, with brackets around IPv6.
String connectAuthority(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

/// Opens a socket to [proxy] and asks it to `CONNECT` to [host]:[port].
/// The task's socket completes once the proxy answered `200`, and fails
/// with a [SocketException] when the proxy refuses (any other status),
/// answers garbage or closes the connection. Cancelling the task closes
/// the connection.
///
/// [connect] opens the connection to the proxy (tests).
Future<ConnectionTask<Socket>> connectTunnel(
  ProxyAddress proxy,
  String host,
  int port, {
  @visibleForTesting
  Future<ConnectionTask<Socket>> Function(String host, int port) connect =
      Socket.startConnect,
}) async {
  final task = await connect(proxy.host, proxy.port);
  var cancelled = false;
  Socket? connected;
  final tunnel = task.socket.then((socket) {
    connected = socket;
    if (cancelled) {
      socket.destroy();
      throw const SocketException('Connection attempt cancelled');
    }
    return openTunnel(socket, connectAuthority(host, port));
  });
  return ConnectionTask.fromSocket(tunnel, () {
    cancelled = true;
    task.cancel();
    connected?.destroy();
  });
}

/// Opens a connection to [proxy], asks it to `CONNECT` to [host]:[port]
/// and runs TLS with [host] through the tunnel ([openSecureTunnel]). The
/// task's socket completes once the TLS handshake is done, and fails with
/// a [SocketException] when the proxy refuses, answers garbage or closes
/// the connection (a `HandshakeException` when TLS fails).
///
/// Cancelling the task (as `dart:io` does once its connection timeout
/// passed) closes the connection at once, also in the middle of the TLS
/// handshake: the connection is a [RawSocket] the tunnel keeps hold of
/// until the handshake is done, because a `dart:io` [Socket] handed to
/// TLS can no longer be closed until the server hangs up. The task's
/// socket then fails with a [SocketException].
///
/// [connect] opens the connection to the proxy and [secure] runs TLS on it
/// (tests; default [startRawConnect] and [RawSecureSocket.secure]);
/// [context] is the TLS trust (default: the system's).
Future<ConnectionTask<Socket>> connectSecureTunnel(
  ProxyAddress proxy,
  String host,
  int port, {
  SecurityContext? context,
  @visibleForTesting RawConnect connect = startRawConnect,
  @visibleForTesting SecureRawSocket secure = RawSecureSocket.secure,
}) async {
  final task = await connect(proxy.host, proxy.port);
  return _securedConnection(
    task,
    (socket) =>
        openSecureTunnel(socket, host, port, context: context, secure: secure),
  );
}

/// The task of a TLS connection on the raw connection of [task], once
/// [handshake] secured it. Cancelling it closes the raw connection at once,
/// also in the middle of the handshake: `dart:io` cannot close a [Socket]
/// that TLS took over until the server hangs up, so the connection is held
/// as a [RawSocket] until [handshake] is done. The task's socket then
/// fails with a [SocketException].
ConnectionTask<Socket> _securedConnection(
  ({Future<RawSocket> socket, void Function() cancel}) task,
  Future<SecureSocket> Function(RawSocket socket) handshake,
) {
  var cancelled = false;
  // The connection until the secured socket is handed over.
  RawSocket? connection;
  final aborted = Completer<Socket>();
  const cancellation = SocketException('Connection attempt cancelled');

  Future<Socket> open() async {
    final socket = await task.socket;
    if (cancelled) {
      unawaited(socket.close());
      throw cancellation;
    }
    connection = socket;
    final Socket secured;
    try {
      secured = await handshake(socket);
    } finally {
      connection = null;
    }
    if (cancelled) {
      secured.destroy();
      throw cancellation;
    }
    return secured;
  }

  return ConnectionTask.fromSocket(
    // The first to finish: the connection, or the cancellation (the
    // attempt may never end on its own once its connection is closed).
    Future.any([open(), aborted.future]),
    () {
      if (cancelled) return;
      cancelled = true;
      task.cancel();
      final open = connection;
      connection = null;
      if (open != null) unawaited(open.close());
      aborted.completeError(cancellation);
    },
  );
}

/// Starts opening a connection to [host]:[port] ([RawConnect]).
typedef RawConnect =
    Future<({Future<RawSocket> socket, void Function() cancel})> Function(
      String host,
      int port,
    );

/// [RawSocket.startConnect] as a [RawConnect].
Future<({Future<RawSocket> socket, void Function() cancel})> startRawConnect(
  String host,
  int port,
) async {
  final task = await RawSocket.startConnect(host, port);
  return (socket: task.socket, cancel: task.cancel);
}

/// Runs TLS on [socket] ([RawSecureSocket.secure]).
typedef SecureRawSocket = Future<RawSecureSocket> Function(
  RawSocket socket, {
  StreamSubscription<RawSocketEvent>? subscription,
  Object? host,
  SecurityContext? context,
});

/// Sends `CONNECT` to [host]:[port] on [socket] (a connection to the
/// proxy) and, once the proxy answered `200`, runs TLS with [host] on it,
/// with [context] (default: the system's trust). Completes with the
/// [SecureSocket] of the tunnel once the handshake is done.
///
/// TLS takes [socket] over in the same event as the proxy's answer, so
/// nothing is read in between. A proxy that sends anything after its
/// answer, before TLS has started, is refused. [socket] is closed when
/// the proxy fails; closing it during the handshake makes the handshake
/// fail. [secure] runs TLS (tests).
@visibleForTesting
Future<SecureSocket> openSecureTunnel(
  RawSocket socket,
  String host,
  int port, {
  SecurityContext? context,
  SecureRawSocket secure = RawSecureSocket.secure,
}) {
  final authority = connectAuthority(host, port);
  final secured = Completer<SecureSocket>();
  final answer = BytesBuilder(copy: false);
  final request = utf8.encode(
    'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n',
  );
  var written = 0;
  var answered = false;
  late final StreamSubscription<RawSocketEvent> subscription;

  void fail(String message) {
    if (answered || secured.isCompleted) return;
    answered = true;
    unawaited(subscription.cancel());
    unawaited(socket.close());
    secured.completeError(SocketException(message));
  }

  void write() {
    try {
      written += socket.write(request, written);
    } on Object catch (error) {
      fail('The proxy connection failed: $error');
      return;
    }
    socket.writeEventsEnabled = written < request.length;
  }

  void read() {
    final data = socket.read();
    if (data == null) return;
    answer.add(data);
    final bytes = answer.toBytes();
    final end = _endOfHeader(bytes);
    if (end < 0) {
      if (bytes.length > _maxAnswerBytes) {
        fail('The proxy sent an invalid answer');
      }
      return;
    }
    final status = _status(bytes.sublist(0, end));
    if (status != 200) {
      fail(
        status == null
            ? 'The proxy sent an invalid answer'
            : 'The proxy refused the connection to $authority (HTTP $status)',
      );
      return;
    }
    if (end < bytes.length) {
      // The server speaks only after the TLS client hello.
      fail('The proxy sent an invalid answer');
      return;
    }
    answered = true;
    // Takes the subscription over at once (it must not be paused).
    unawaited(
      secure(
        socket,
        subscription: subscription,
        host: host,
        context: context,
      ).then(
        (tls) => secured.complete(_SecureTunnelSocket(tls)),
        onError: secured.completeError,
      ),
    );
  }

  subscription = socket.listen(
    (event) {
      if (answered) return;
      switch (event) {
        case RawSocketEvent.read:
          read();
        case RawSocketEvent.write:
          if (written < request.length) write();
        case RawSocketEvent.readClosed:
          fail('The proxy closed the connection');
        case RawSocketEvent.closed:
          fail('The proxy closed the connection');
      }
    },
    onError: (Object error, StackTrace stackTrace) =>
        fail('The proxy connection failed: $error'),
    onDone: () => fail('The proxy closed the connection'),
  );
  socket.readEventsEnabled = true;
  write();
  return secured.future;
}

/// Longest proxy answer read before giving up on it.
const int _maxAnswerBytes = 16 * 1024;

/// Sends `CONNECT` [authority] on [socket] (connected to the proxy) and
/// completes with the tunnel once the proxy answered `200`; see
/// [connectTunnel].
@visibleForTesting
Future<Socket> openTunnel(Socket socket, String authority) {
  final opened = Completer<Socket>();
  final incoming = StreamController<Uint8List>();
  final answer = BytesBuilder(copy: false);
  var open = false;
  late final StreamSubscription<Uint8List> subscription;

  void fail(String message) {
    if (opened.isCompleted) return;
    unawaited(subscription.cancel());
    socket.destroy();
    opened.completeError(SocketException(message));
  }

  void onAnswer(Uint8List data) {
    answer.add(data);
    final bytes = answer.toBytes();
    final end = _endOfHeader(bytes);
    if (end < 0) {
      if (bytes.length > _maxAnswerBytes) {
        fail('The proxy sent an invalid answer');
      }
      return;
    }
    final status = _status(bytes.sublist(0, end));
    if (status != 200) {
      fail(
        status == null
            ? 'The proxy sent an invalid answer'
            : 'The proxy refused the connection to $authority (HTTP $status)',
      );
      return;
    }
    open = true;
    // Nothing is read until dart:io listens.
    subscription.pause();
    if (end < bytes.length) incoming.add(Uint8List.sublistView(bytes, end));
    incoming
      ..onListen = subscription.resume
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
    opened.complete(_TunnelSocket(socket, incoming.stream));
  }

  subscription = socket.listen(
    (data) => open ? incoming.add(data) : onAnswer(data),
    onError: (Object error, StackTrace stackTrace) => open
        ? incoming.addError(error, stackTrace)
        : fail('The proxy connection failed: $error'),
    onDone: () => open
        ? unawaited(incoming.close())
        : fail('The proxy closed the connection'),
  );
  socket.add(
    utf8.encode('CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n'),
  );
  return opened.future;
}

/// The index after the blank line ending the header in [bytes], or -1.
int _endOfHeader(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return i + 4;
    }
  }
  return -1;
}

/// The status code of an HTTP answer [header] (`HTTP/1.1 200 OK`).
int? _status(Uint8List header) {
  final line = latin1.decode(header).split('\r\n').first.split(' ');
  if (line.length < 2 || !line.first.startsWith('HTTP/')) return null;
  return int.tryParse(line[1]);
}

/// [_socket] after the proxy's answer: reads continue from [_incoming]
/// (which holds anything the proxy sent after its answer), writes go to
/// [_socket]. Like `dart:io`'s own detached sockets.
class _TunnelSocket extends Stream<Uint8List> implements Socket {
  new(this._socket, this._incoming);

  final Socket _socket;
  final Stream<Uint8List> _incoming;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      _socket.addStream(stream);

  @override
  void destroy() => _socket.destroy();

  @override
  Future<dynamic> flush() => _socket.flush();

  @override
  Future<dynamic> close() => _socket.close();

  @override
  Future<dynamic> get done => _socket.done;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}

/// A [SecureSocket] over a [RawSecureSocket] (of a tunnel,
/// [openSecureTunnel], or of a connection to a checked address,
/// [connectSecureAddress]): `dart:io` has no public way to wrap one, so this
/// does what its own sockets do. Reads go to the listener (and stop while
/// it pauses), writes are queued until the connection takes them.
class _SecureTunnelSocket extends Stream<Uint8List> implements SecureSocket {
  new(this._raw) {
    _raw
      ..readEventsEnabled = false
      ..writeEventsEnabled = false;
    _incoming = StreamController<Uint8List>(
      onListen: _updateReads,
      onPause: _updateReads,
      onResume: _updateReads,
      onCancel: _cancelReads,
    );
    _subscription = _raw.listen(_onEvent, onError: _onError, onDone: _end);
    // Errors also reach the listener; nobody has to wait for [done].
    _done.future.ignore();
  }

  final RawSecureSocket _raw;
  late final StreamController<Uint8List> _incoming;
  late final StreamSubscription<RawSocketEvent> _subscription;
  final _done = Completer<Object?>();
  final _pending = ListQueue<List<int>>();
  final _flushes = <Completer<void>>[];
  var _offset = 0;

  /// [close] was called: nothing more may be added.
  var _closing = false;

  /// The connection is gone (destroyed, closed or failed).
  var _closed = false;

  @override
  Encoding encoding = utf8;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  void _updateReads() {
    if (_closed) return;
    _raw.readEventsEnabled = _incoming.hasListener && !_incoming.isPaused;
  }

  void _cancelReads() {
    if (!_closed) _raw.shutdown(SocketDirection.receive);
  }

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _closed ? null : _raw.read();
        if (data != null && data.isNotEmpty) _incoming.add(data);
      case RawSocketEvent.write:
        _write();
      case RawSocketEvent.readClosed:
        _closeIncoming();
      case RawSocketEvent.closed:
        _end();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_incoming.isClosed) _incoming.addError(error, stackTrace);
    _fail(error, stackTrace);
  }

  void _closeIncoming() {
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  /// The connection ended: reads end, waiting writes are dropped.
  void _end() {
    _closed = true;
    _pending.clear();
    _closeIncoming();
    _settle();
    if (!_done.isCompleted) _done.complete(this);
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    unawaited(_raw.close());
    _closeIncoming();
    _settle();
    if (!_done.isCompleted) _done.completeError(error, stackTrace);
  }

  /// Completes the waiting [flush]es.
  void _settle() {
    for (final flush in _flushes) {
      flush.complete();
    }
    _flushes.clear();
  }

  void _write() {
    if (_closed) return;
    try {
      while (_pending.isNotEmpty) {
        final chunk = _pending.first;
        _offset += _raw.write(chunk, _offset);
        if (_offset < chunk.length) {
          _raw.writeEventsEnabled = true;
          return;
        }
        _pending.removeFirst();
        _offset = 0;
      }
    } on Object catch (error, stackTrace) {
      _fail(error, stackTrace);
      return;
    }
    _settle();
    if (_closing) _shutdownWrite();
  }

  void _shutdownWrite() {
    if (_closed) return;
    _raw.shutdown(SocketDirection.send);
    if (!_done.isCompleted) _done.complete(this);
  }

  @override
  void add(List<int> data) {
    if (_closing) throw StateError('StreamSink is closed');
    if (_closed || data.isEmpty) return;
    _pending.add(data);
    _write();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _fail(error, stackTrace ?? StackTrace.current);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) {
    final added = Completer<void>();
    stream.listen(
      add,
      onError: added.completeError,
      onDone: () => added.complete(flush()),
      cancelOnError: true,
    );
    return added.future;
  }

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  Future<dynamic> flush() {
    if (_closed || _pending.isEmpty) return Future<void>.value();
    final flushed = Completer<void>();
    _flushes.add(flushed);
    return flushed.future;
  }

  @override
  Future<dynamic> close() {
    if (!_closing) {
      _closing = true;
      if (_pending.isEmpty) _shutdownWrite();
    }
    return _done.future;
  }

  @override
  void destroy() {
    if (_closed) return;
    unawaited(_raw.close());
    unawaited(_subscription.cancel());
    _end();
  }

  @override
  Future<dynamic> get done => _done.future;

  @override
  X509Certificate? get peerCertificate => _raw.peerCertificate;

  @override
  String? get selectedProtocol => _raw.selectedProtocol;

  @override
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) => throw UnsupportedError('Renegotiation is not supported');

  @override
  int get port => _raw.port;

  @override
  InternetAddress get address => _raw.address;

  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;

  @override
  int get remotePort => _raw.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);
}
