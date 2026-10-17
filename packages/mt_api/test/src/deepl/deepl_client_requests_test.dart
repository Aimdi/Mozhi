import 'dart:convert';

import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Request minimisation of [DeeplClient.translate].
void main() {
  late RecordingClient http;
  late DeeplClient client;

  setUp(() {
    http = RecordingClient((request) {
      final texts = (jsonDecode(request.body) as Map)['text'] as List;
      return jsonResponse({
        'translations': [
          for (final text in texts)
            {'detected_source_language': 'DE', 'text': 'T($text)'},
        ],
      });
    });
    client = DeeplClient(authKey: 'key:fx', httpClient: http);
  });

  group('blank text', () {
    test('is not sent; its slot keeps the input', () async {
      final results = await client.translate(
        texts: const ['eins', '', 'zwei', ' \n'],
        targetLang: 'EN-US',
      );

      expect((jsonDecode(http.single.body) as Map)['text'], ['eins', 'zwei']);
      expect(results.map((r) => (r.text, r.detectedSourceLanguage)), [
        ('T(eins)', 'DE'),
        ('', ''),
        ('T(zwei)', 'DE'),
        (' \n', ''),
      ]);
    });

    test('alone makes no request', () async {
      final result = await client.translateText(text: '  ', targetLang: 'DE');

      expect(result.text, '  ');
      expect(result.detectedSourceLanguage, isEmpty);
      expect(http.requests, isEmpty);
    });

    test('does not count towards the texts per request', () async {
      final texts = [
        for (var i = 0; i < DeeplClient.maxTextsPerRequest + 1; i++) ...[
          'text $i',
          '',
        ],
      ];

      final results = await client.translate(texts: texts, targetLang: 'EN');

      expect(http.requests, hasLength(2));
      expect(
        (jsonDecode(http.requests.first.body) as Map)['text'],
        hasLength(DeeplClient.maxTextsPerRequest),
      );
      expect((jsonDecode(http.requests.last.body) as Map)['text'], [
        'text ${DeeplClient.maxTextsPerRequest}',
      ]);
      expect(results, hasLength(texts.length));
      expect(results[0].text, 'T(text 0)');
      expect(results[1].text, '');
      expect(results.last.text, '');
      expect(
        results[texts.length - 2].text,
        'T(text ${DeeplClient.maxTextsPerRequest})',
      );
    });
  });
}
