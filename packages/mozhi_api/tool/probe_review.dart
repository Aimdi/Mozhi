import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mozhi_api/mozhi_api.dart';

/// Mimics fasthttp: when Content-Length > limit, write 413 without reading
/// the body and close the connection.
Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) async {
    final buf = <int>[];
    late StreamSubscription<List<int>> sub;
    sub = socket.listen((data) async {
      buf.addAll(data);
      final s = String.fromCharCodes(buf);
      if (s.contains('\r\n\r\n')) {
        await sub.cancel();
        socket.add('HTTP/1.1 413 Request Entity Too Large\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 24\r\nConnection: close\r\n\r\nRequest Entity Too Large'.codeUnits);
        await socket.flush();
        socket.destroy();
      }
    }, onError: (_) {});
  });
  final client = MozhiApiClient(baseUrl: Uri.parse('http://127.0.0.1:${server.port}'));
  for (final size in [100 * 1024, 6 * 1024 * 1024]) {
    try {
      await client.translateImage(pngBytes: Uint8List(size), from: 'fr', to: 'en');
    } on MozhiApiException catch (e) {
      print('size=$size -> status=${e.statusCode} retryable=${e.isRetryable} msg=${e.message}');
    }
  }
  exit(0);
}
