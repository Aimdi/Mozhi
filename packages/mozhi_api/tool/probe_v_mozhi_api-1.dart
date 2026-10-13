// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:mozhi_api/mozhi_api.dart';

Future<void> main() async {
  // "https" target: a plain http server that acts like the real instance.
  final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  target.listen((req) async {
    final body = await utf8.decoder.bind(req).join();
    print('  target got ${req.method} ${req.uri} body="$body"');
    req.response.headers.contentType = ContentType.json;
    if (req.uri.path == '/api/version') {
      req.response.write('{"fiberversion":"x","goversion":"y"}');
    } else if (req.uri.path == '/api/translate') {
      if (req.method == 'GET' && req.uri.queryParameters.isEmpty) {
        req.response.statusCode = 400;
        req.response.headers.contentType = ContentType.text;
        req.response.write('from, to, engine, text are required query strings.');
      } else {
        req.response.write(
          '{"engine":"google","translated-text":"hola","source_language":"en","target_language":"es"}',
        );
      }
    } else if (req.uri.path == '/api/engines') {
      req.response.write('{"google":"Google"}');
    }
    await req.response.close();
  });
  for (final code in [301, 302, 307, 308, 303]) {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((req) async {
      await req.drain<void>();
      req.response
        ..statusCode = code
        ..headers.set(
          'location',
          'http://127.0.0.1:${target.port}${req.uri}',
        );
      await req.response.close();
    });
    print('=== proxy redirect $code ===');
    final client = MozhiApiClient(
      baseUrl: Uri.parse('http://127.0.0.1:${proxy.port}'),
    );
    try {
      print('ping ok: ${await client.ping()}');
    } on MozhiApiException catch (e) {
      print('ping failed: $e');
    }
    try {
      print('engines: ${await client.getEngines()}');
    } on MozhiApiException catch (e) {
      print('engines failed: $e');
    }
    try {
      final t = await client.translate(
        engine: 'google',
        from: 'en',
        to: 'es',
        text: 'hello',
      );
      print('translate ok: ${t.translatedText}');
    } on MozhiApiException catch (e) {
      print('translate failed: $e retryable=${e.isRetryable}');
    }
    client.close();
    await proxy.close(force: true);
  }
  await target.close(force: true);
}
