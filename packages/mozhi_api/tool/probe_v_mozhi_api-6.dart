// Temporary probe for finding mozhi_api-6. Delete after use.
// ignore_for_file: avoid_print
import 'package:mozhi_api/mozhi_api.dart';

Future<void> main() async {
  final client = MozhiApiClient(
    baseUrl: Uri.parse('http://127.0.0.1:3196'),
    timeout: const Duration(seconds: 20),
  );
  // Tamil word "தமிழ்" (5 code units, 3 bytes UTF-8 each) + space.
  const tamilWord = 'தமிழ் ';
  const chinese = '你好世界今天天气很好';
  final cases = <String, String>{
    'ta-300': (tamilWord * 60).substring(0, 300),
    'ta-400': (tamilWord * 80).substring(0, 400),
    'ta-430': (tamilWord * 90).substring(0, 430),
    'ta-450': (tamilWord * 90).substring(0, 450),
    'ta-600': (tamilWord * 120).substring(0, 600),
    'zh-400': (chinese * 40).substring(0, 400),
    'zh-450': (chinese * 45).substring(0, 450),
    'en-250': ('hello world ' * 30).substring(0, 250),
  };
  for (final MapEntry(key: name, value: text) in cases.entries) {
    final lang = name.split('-').first;
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: 3196,
      path: '/api/tts',
      queryParameters: {'engine': 'google', 'lang': lang, 'text': text},
    );
    final requestLineLen = 'GET ${uri.path}?${uri.query} HTTP/1.1\r\n'.length;
    try {
      final bytes = await client.textToSpeech(
        engine: 'google',
        language: lang,
        text: text,
      );
      print(
        '$name chars=${text.length} reqLine=$requestLineLen -> OK '
        '${bytes.length} bytes',
      );
    } on MozhiApiException catch (e) {
      print(
        '$name chars=${text.length} reqLine=$requestLineLen -> '
        'status=${e.statusCode} retryable=${e.isRetryable} msg=${e.message}',
      );
    }
  }
  client.close();
}
