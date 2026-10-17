import 'dart:async';
import 'dart:convert';

import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

import '../helpers.dart';

final Uri _base = Uri.parse('https://translate.example.org');

/// Request minimisation, cancellation and key placement of
/// [LibreTranslateClient].
void main() {
  late RecordingClient http;
  late LibreTranslateClient client;

  setUp(() {
    http = RecordingClient((request) {
      if (request.url.path == '/detect') {
        return jsonResponse('[{"confidence":90,"language":"de"}]');
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final q = body['q'];
      return jsonResponse({
        'translatedText': q is List
            ? [for (final text in q) 'T($text)']
            : 'T($q)',
      });
    });
    client = LibreTranslateClient(
      baseUrl: _base,
      apiKey: 'k3y',
      httpClient: http,
    );
  });

  group('the API key', () {
    test('only travels in the JSON body', () async {
      await client.translate(text: 'Hallo', target: 'en', alternatives: 3);
      await client.detect('Hallo');

      for (final request in http.requests) {
        expect(request.url.hasQuery, isFalse);
        expect(request.url.userInfo, isEmpty);
        expect(request.headers.values.join(' '), isNot(contains('k3y')));
        expect((jsonDecode(request.body) as Map)['api_key'], 'k3y');
      }
      expect(jsonDecode(http.requests.first.body), {
        'q': 'Hallo',
        'source': 'auto',
        'target': 'en',
        'format': 'text',
        'alternatives': 3,
        'api_key': 'k3y',
      });
    });

    test('is not sent with the language list', () async {
      http = RecordingClient((_) => jsonResponse('[]'));
      await LibreTranslateClient(
        baseUrl: _base,
        apiKey: 'k3y',
        httpClient: http,
      ).languages();

      expect(http.single.method, 'GET');
      expect(http.single.url.toString(), '$_base/languages');
      expect(http.single.body, isEmpty);
    });
  });

  group('blank text', () {
    test('translate returns it without a request', () async {
      final result = await client.translate(text: ' \n ', target: 'en');

      expect(result, const LibreTranslation(text: ' \n '));
      expect(http.requests, isEmpty);
    });

    test('translateBatch only sends the texts that are not blank', () async {
      final results = await client.translateBatch(
        texts: const ['', 'eins', '  ', 'zwei'],
        target: 'en',
      );

      expect((jsonDecode(http.single.body) as Map)['q'], ['eins', 'zwei']);
      expect(results.map((r) => r.text), ['', 'T(eins)', '  ', 'T(zwei)']);
    });

    test('translateBatch of blank texts makes no request', () async {
      final results = await client.translateBatch(
        texts: const ['', ' '],
        target: 'en',
      );

      expect(results.map((r) => r.text), ['', ' ']);
      expect(http.requests, isEmpty);
    });

    test('detect finds nothing without a request', () async {
      expect(await client.detect('   '), isEmpty);
      expect(http.requests, isEmpty);
    });
  });

  group('abortTrigger', () {
    final calls =
        <String, Future<Object?> Function(LibreTranslateClient, Future<void>)>{
          'translateBatch': (c, abort) => c.translateBatch(
            texts: const ['x'],
            target: 'en',
            abortTrigger: abort,
          ),
          'detect': (c, abort) => c.detect('x', abortTrigger: abort),
          'languages': (c, abort) => c.languages(abortTrigger: abort),
          'settings': (c, abort) => c.settings(abortTrigger: abort),
        };

    for (final MapEntry(key: name, value: call) in calls.entries) {
      test('cancels $name', () async {
        final hanging = HangingClient();
        final abort = Completer<void>();

        final result = call(
          LibreTranslateClient(baseUrl: _base, httpClient: hanging),
          abort.future,
        );
        await pumpEventQueue();
        abort.complete();

        await expectLater(
          result,
          throwsMtError<LibreTranslateException>(kind: MtErrorKind.cancelled),
        );
        expect(hanging.sawAbort, isTrue);
      });
    }
  });
}
