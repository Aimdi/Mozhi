// Temporary probe: mimics fasthttp's MaxRequestBodySize rejection
// (413 + close before reading the body).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mozhi_api/mozhi_api.dart';

const limit = 4 * 1024 * 1024;

Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    final buf = BytesBuilder();
    var handled = false;
    socket.listen((data) {
      if (handled) return; // ignore body bytes after headers
      buf.add(data);
      final text = latin1.decode(buf.toBytes(), allowInvalid: true);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) return;
      handled = true;
      final m = RegExp(r'content-length:\s*(\d+)', caseSensitive: false)
          .firstMatch(text.substring(0, end));
      final len = int.parse(m!.group(1)!);
      if (len > limit) {
        socket.add(latin1.encode(
          'HTTP/1.1 413 Request Entity Too Large\r\n'
          'Content-Type: text/plain\r\nContent-Length: 24\r\n'
          'Connection: close\r\n\r\nRequest Entity Too Large',
        ));
        socket.flush().then((_) => socket.destroy());
      } else {
        // Read the rest then reply OK.
        var got = buf.length - (end + 4);
        void reply() {
          final body = '{"TranslatedImgB64":"QQ=="}';
          socket.add(latin1.encode('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
              'Content-Length: ${body.length}\r\nConnection: close\r\n\r\n$body'));
          socket.flush().then((_) => socket.destroy());
        }
        if (got >= len) {
          reply();
        } else {
          handled = false;
          socket.listen(null).cancel();
        }
      }
    }, onError: (_) {});
  });
  final client = MozhiApiClient(
    baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
  );
  for (final size in [100 * 1024, 6 * 1024 * 1024, 20 * 1024 * 1024]) {
    try {
      await client.translateImage(
        pngBytes: Uint8List(size),
        from: 'en',
        to: 'fr',
      );
      print('size=$size OK');
    } on MozhiApiException catch (e) {
      print('size=$size -> $e status=${e.statusCode} retryable=${e.isRetryable}');
    }
  }
  client.close();
  await server.close();
}
