import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mozhi/core/network/http_client_factory.dart';

/// Routes [client]'s connections through the HTTP proxy at [proxy], except
/// connections to hosts for which [bypass] is true, which are direct.
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
/// Host names are resolved by the proxy, never locally. [context] is the
/// TLS trust of `https` connections (default: the system's; tests).
void routeThroughProxy(
  HttpClient client,
  ProxyAddress proxy, {
  required bool Function(String host) bypass,
  SecurityContext? context,
}) {
  client
    // The tunnels are the connection factory's: dart:io connects "directly"
    // to what it returns and adds no TLS of its own.
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, _, _) {
      final secure = uri.isScheme('https');
      if (bypass(uri.host)) {
        return secure
            ? SecureSocket.startConnect(uri.host, uri.port, context: context)
            : Socket.startConnect(uri.host, uri.port);
      }
      return secure
          ? connectSecureTunnel(proxy, uri.host, uri.port, context: context)
          : connectTunnel(proxy, uri.host, uri.port);
    };
}

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

/// Opens a socket to [proxy], asks it to `CONNECT` to [host]:[port] and
/// runs TLS with [host] through the tunnel ([openSecureTunnel]). The
/// task's socket completes once the TLS handshake is done, and fails with
/// a [SocketException] when the proxy refuses, answers garbage or closes
/// the connection (a `HandshakeException` when TLS fails). Cancelling the
/// task closes the connection.
///
/// [connect] opens the connection to the proxy (tests); [context] is the
/// TLS trust (default: the system's).
Future<ConnectionTask<Socket>> connectSecureTunnel(
  ProxyAddress proxy,
  String host,
  int port, {
  SecurityContext? context,
  @visibleForTesting
  Future<ConnectionTask<Socket>> Function(String host, int port) connect =
      Socket.startConnect,
}) async {
  final task = await connect(proxy.host, proxy.port);
  var cancelled = false;
  Socket? connected;
  Never stop() {
    connected?.destroy();
    throw const SocketException('Connection attempt cancelled');
  }

  final tunnel = task.socket.then((socket) async {
    connected = socket;
    if (cancelled) stop();
    final secure = await openSecureTunnel(socket, host, port, context: context);
    connected = secure;
    if (cancelled) stop();
    return secure as Socket;
  });
  return ConnectionTask.fromSocket(tunnel, () {
    cancelled = true;
    task.cancel();
    connected?.destroy();
  });
}

/// Sends `CONNECT` to [host]:[port] on [socket] (a `dart:io` socket
/// connected to the proxy) and, once the proxy answered `200`, runs TLS
/// with [host] on it, with [context] (default: the system's trust).
///
/// The answer is read from [socket] itself (TLS can only take over a
/// `dart:io` socket, not a wrapper such as the plain tunnel's): its
/// subscription is paused, not cancelled, after the answer (cancelling
/// would stop the socket from reading), and TLS takes the connection over.
/// A proxy that sends anything after its answer, before TLS has started,
/// is refused.
@visibleForTesting
Future<SecureSocket> openSecureTunnel(
  Socket socket,
  String host,
  int port, {
  SecurityContext? context,
}) async {
  final authority = connectAuthority(host, port);
  final answered = Completer<void>();
  final answer = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> subscription;

  void fail(String message) {
    if (answered.isCompleted) return;
    unawaited(subscription.cancel());
    socket.destroy();
    answered.completeError(SocketException(message));
  }

  subscription = socket.listen(
    (data) {
      if (answered.isCompleted) return;
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
      subscription.pause();
      answered.complete();
    },
    onError: (Object error, StackTrace stackTrace) =>
        fail('The proxy connection failed: $error'),
    onDone: () => fail('The proxy closed the connection'),
  );
  socket.add(
    utf8.encode('CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n'),
  );
  await answered.future;
  try {
    return await SecureSocket.secure(socket, host: host, context: context);
  } finally {
    // Detached from the connection by now, so cancelling stops nothing.
    unawaited(subscription.cancel());
  }
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
