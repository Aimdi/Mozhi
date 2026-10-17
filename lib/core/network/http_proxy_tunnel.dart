import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:mozhi/core/network/http_client_factory.dart';

/// Routes [client]'s connections through the HTTP proxy at [proxy], except
/// connections to hosts for which [bypass] is true, which are direct.
///
/// * `https`: `dart:io` opens the `CONNECT` tunnel itself ([proxyDirective]
///   answers `PROXY host:port`) and runs TLS through it.
/// * plain `http` (Tor `.onion` services, I2P sites): the tunnel is opened
///   here ([connectTunnel]). `dart:io` would send proxy-style requests
///   (`GET http://…`) instead, which Tor's HTTP tunnel port refuses.
///
/// Host names are resolved by the proxy, never locally.
void routeThroughProxy(
  HttpClient client,
  ProxyAddress proxy, {
  required bool Function(String host) bypass,
}) {
  client
    ..findProxy = ((uri) => proxyDirective(uri, proxy, bypass: bypass))
    ..connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null && proxyPort != null) {
        // `https` through the proxy: dart:io sends CONNECT on this socket.
        return Socket.startConnect(proxyHost, proxyPort);
      }
      if (bypass(uri.host)) {
        // With a connection factory dart:io adds no TLS of its own.
        return uri.isScheme('https')
            ? SecureSocket.startConnect(uri.host, uri.port)
            : Socket.startConnect(uri.host, uri.port);
      }
      return connectTunnel(proxy, uri.host, uri.port);
    };
}

/// The `findProxy` answer for [uri]: `PROXY host:port` for `https` to hosts
/// that do not [bypass] the proxy, else `DIRECT` (plain `http` is tunnelled
/// by the connection factory, see [routeThroughProxy]).
String proxyDirective(
  Uri uri,
  ProxyAddress proxy, {
  required bool Function(String host) bypass,
}) => uri.isScheme('https') && !bypass(uri.host)
    ? 'PROXY ${proxy.authority}'
    : 'DIRECT';

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
