// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mozhi_api/mozhi_api.dart';

final _sw = Stopwatch()..start();
String get _t => '${_sw.elapsedMilliseconds.toString().padLeft(5)} ms';

/// Raw TCP server: reads the request, waits [delay], replies. Logs when the
/// client closes the socket and how many request bytes arrived.
Future<ServerSocket> _server(String name, Duration delay) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    var bytes = 0;
    var replied = false;
    var closedByClient = false;
    print('$_t [$name] connection accepted');
    socket.listen(
      (data) {
        bytes += data.length;
        if (!replied) {
          replied = true;
          Timer(delay, () {
            if (closedByClient) {
              print('$_t [$name] wanted to reply but client already closed');
              return;
            }
            const body = '{"engine":"google","translated-text":"hi"}';
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
                'Content-Length: ${body.length}\r\n\r\n$body',
              ),
            );
            print('$_t [$name] reply written (received $bytes bytes)');
          });
        }
      },
      onDone: () {
        closedByClient = true;
        print('$_t [$name] client closed connection (received $bytes bytes)');
        socket.destroy();
      },
      onError: (Object e) {
        closedByClient = true;
        print('$_t [$name] socket error $e');
      },
    );
  });
  return server;
}

Future<void> main() async {
  // 1. Current client: 200 ms timeout, server answers after 1500 ms.
  print('--- current MozhiApiClient (Future.timeout) ---');
  final s1 = await _server('s1', const Duration(milliseconds: 1500));
  final client = MozhiApiClient(
    baseUrl: Uri.parse('http://127.0.0.1:${s1.port}'),
    timeout: const Duration(milliseconds: 200),
  );
  try {
    await client.translate(engine: 'google', from: 'en', to: 'de', text: 'x');
  } on MozhiApiException catch (e) {
    print('$_t client threw: ${e.message}');
  }
  await Future<void>.delayed(const Duration(milliseconds: 2500));
  print('$_t (no "client closed" line above before reply => not aborted)');

  // 2. Large multipart upload after timeout: does the body keep flowing?
  print('--- multipart upload (8 MB) with 200 ms timeout ---');
  final s2 = await _server('s2', const Duration(milliseconds: 3000));
  final client2 = MozhiApiClient(
    baseUrl: Uri.parse('http://127.0.0.1:${s2.port}'),
    timeout: const Duration(milliseconds: 200),
  );
  try {
    await client2.translateImage(
      pngBytes: Uint8List(8 * 1024 * 1024),
      from: 'en',
      to: 'de',
    );
  } on MozhiApiException catch (e) {
    print('$_t client2 threw: ${e.message}');
  }
  await Future<void>.delayed(const Duration(milliseconds: 3500));

  // 3. The proposed fix: AbortableRequest + abortTrigger.
  print('--- AbortableRequest with abortTrigger after 200 ms ---');
  final s3 = await _server('s3', const Duration(milliseconds: 1500));
  final raw = http.Client();
  final trigger = Completer<void>();
  final timer = Timer(const Duration(milliseconds: 200), trigger.complete);
  try {
    final req = http.AbortableRequest(
      'POST',
      Uri.parse('http://127.0.0.1:${s3.port}/api/translate'),
      abortTrigger: trigger.future,
    )..bodyFields = {'engine': 'google', 'from': 'en', 'to': 'de', 'text': 'x'};
    await http.Response.fromStream(await raw.send(req));
  } on http.RequestAbortedException catch (e) {
    print('$_t aborted: $e');
  } finally {
    timer.cancel();
  }
  await Future<void>.delayed(const Duration(milliseconds: 2000));

  client.close();
  client2.close();
  raw.close();
  await s1.close();
  await s2.close();
  await s3.close();
}
