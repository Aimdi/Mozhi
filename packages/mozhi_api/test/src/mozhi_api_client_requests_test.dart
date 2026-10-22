import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

final Uri _baseUrl = Uri.parse('https://mozhi.example');

http.Response _json(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _redirect(int status, String location) =>
    http.Response('', status, headers: {'location': location});

/// An [http.Client] that never answers until the request is aborted.
class _HangingClient extends http.BaseClient {
  final sent = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent.add(request);
    final completer = Completer<http.StreamedResponse>();
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          if (!completer.isCompleted) {
            completer.completeError(http.RequestAbortedException(request.url));
          }
        }),
      );
    }
    return completer.future;
  }
}

Matcher get _throwsCancelled => throwsA(
  isA<MozhiRequestCancelledException>()
      .having((e) => e.statusCode, 'statusCode', isNull)
      .having((e) => e.isRetryable, 'isRetryable', isFalse)
      .having((e) => e.message, 'message', 'The request was cancelled.'),
);

void main() {
  late List<http.BaseRequest> requests;

  setUp(() => requests = []);

  MozhiApiClient clientAnswering(List<http.Response> responses) {
    final queue = Queue.of(responses);
    return MozhiApiClient(
      baseUrl: _baseUrl,
      httpClient: MockClient((request) async {
        requests.add(request);
        return queue.removeFirst();
      }),
    );
  }

  group('blank text', () {
    for (final text in ['', '  \n\t ']) {
      test('translate answers ${jsonEncode(text)} without a request', () async {
        final translation = await clientAnswering(const [])
            .translate(engine: 'google', from: 'en', to: 'de', text: text);

        expect(translation.engine, 'google');
        expect(translation.translatedText, text);
        expect(translation.sourceLanguage, 'en');
        expect(translation.targetLanguage, 'de');
        expect(requests, isEmpty);
      });
    }

    test('translateWithEngines answers one empty result per engine', () async {
      final client = clientAnswering(const []);

      final some = await client.translateWithEngines(
        engines: const ['google', 'deepl'],
        from: 'auto',
        to: 'fr',
        text: ' ',
      );
      final all = await client.translateWithEngines(
        engines: const [],
        from: 'auto',
        to: 'fr',
        text: '',
      );

      expect(some.map((t) => (t.engine, t.translatedText)), [
        ('google', ' '),
        ('deepl', ' '),
      ]);
      expect(all, isEmpty);
      expect(requests, isEmpty);
    });

    test('textToSpeech rejects it without a request', () async {
      await expectLater(
        clientAnswering(const [])
            .textToSpeech(engine: 'google', language: 'en', text: '  '),
        throwsArgumentError,
      );
      expect(requests, isEmpty);
    });
  });

  group('abortTrigger', () {
    final calls =
        <String, Future<Object?> Function(MozhiApiClient, Future<void>)>{
          'translate': (c, abort) => c.translate(
            engine: 'google',
            from: 'en',
            to: 'de',
            text: 'hello',
            abortTrigger: abort,
          ),
          'translateWithEngines': (c, abort) => c.translateWithEngines(
            engines: const ['google'],
            from: 'en',
            to: 'de',
            text: 'hello',
            abortTrigger: abort,
          ),
          'textToSpeech': (c, abort) => c.textToSpeech(
            engine: 'google',
            language: 'en',
            text: 'hello',
            abortTrigger: abort,
          ),
          'translateImage': (c, abort) => c.translateImage(
            pngBytes: Uint8List.fromList(const [137, 80, 78, 71]),
            from: 'fr',
            to: 'en',
            abortTrigger: abort,
          ),
        };

    for (final MapEntry(key: name, value: call) in calls.entries) {
      test('$name aborts an in-flight request', () async {
        final http = _HangingClient();
        final client = MozhiApiClient(baseUrl: _baseUrl, httpClient: http);
        final abort = Completer<void>();

        final result = call(client, abort.future);
        await pumpEventQueue();
        expect(http.sent, hasLength(1));
        abort.complete();

        await expectLater(result, _throwsCancelled);
      });
    }

    test('an error completing the trigger cancels too', () async {
      final client = MozhiApiClient(
        baseUrl: _baseUrl,
        httpClient: _HangingClient(),
      );
      final abort = Completer<void>();

      final result = calls['translate']!(client, abort.future);
      await pumpEventQueue();
      abort.completeError(StateError('gone'));

      await expectLater(result, _throwsCancelled);
    });

    test('drops a response that arrives after the cancellation', () async {
      final answer = Completer<http.Response>();
      final client = MozhiApiClient(
        baseUrl: _baseUrl,
        // Ignores the abort trigger.
        httpClient: MockClient((_) => answer.future),
      );
      final abort = Completer<void>();

      final result = calls['translate']!(client, abort.future);
      await pumpEventQueue();
      abort.complete();
      await pumpEventQueue();
      answer.complete(_json(googleTranslationJson));

      await expectLater(result, _throwsCancelled);
    });

    test('does not follow a redirect after the cancellation', () async {
      final answer = Completer<http.Response>();
      final client = MozhiApiClient(
        baseUrl: _baseUrl,
        httpClient: MockClient((request) {
          requests.add(request);
          return answer.future;
        }),
      );
      final abort = Completer<void>();

      final result = calls['translate']!(client, abort.future);
      await pumpEventQueue();
      abort.complete();
      answer.complete(_redirect(307, 'https://mozhi.example/v2/api/translate'));

      await expectLater(result, _throwsCancelled);
      expect(requests, hasLength(1));
    });

    test('a cancellation racing the timeout reads as cancelled', () async {
      final client = MozhiApiClient(
        baseUrl: _baseUrl,
        httpClient: MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 20),
      );
      final abort = Completer<void>()..complete();

      await expectLater(
        calls['translate']!(client, abort.future),
        _throwsCancelled,
      );
    });

    test('an untriggered request completes normally', () async {
      final translation = await calls['translate']!(
        clientAnswering([_json(googleTranslationJson)]),
        Completer<void>().future,
      );

      expect((translation! as MozhiTranslation).translatedText, 'cat');
    });
  });

  group('GET redirects', () {
    test('follows a 303 for a GET', () async {
      final engines = await clientAnswering([
        _redirect(303, '/v2/api/engines'),
        _json(enginesJson),
      ]).getEngines();

      expect(engines, isNotEmpty);
      expect(requests.map((r) => (r.method, r.url.path)), [
        ('GET', '/api/engines'),
        ('GET', '/v2/api/engines'),
      ]);
      expect(requests.every((r) => !r.followRedirects), isTrue);
    });

    test('never downgrades a GET carrying text to plain http', () async {
      await expectLater(
        clientAnswering([
          _redirect(302, 'http://mozhi.example/api/tts?text=secret'),
        ]).textToSpeech(engine: 'google', language: 'en', text: 'secret'),
        throwsA(
          isA<MozhiApiException>()
              .having((e) => e.statusCode, 'status', 302)
              .having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
      expect(requests, hasLength(1));
    });

    test('never sends a GET carrying text to another server', () async {
      await expectLater(
        clientAnswering([
          _redirect(307, 'https://nas.tail123.ts.net/api/tts?text=secret'),
          _json('{}'),
        ]).textToSpeech(engine: 'google', language: 'en', text: 'secret'),
        throwsA(
          isA<MozhiApiException>()
              .having((e) => e.statusCode, 'status', 307)
              .having(
                (e) => e.message,
                'message',
                'Redirected to https://nas.tail123.ts.net, a different '
                    'server. Add that address as an instance to use it.',
              ),
        ),
      );
      expect(requests.single.url.host, 'mozhi.example');
    });

    test('keeps the credentials on the origin of the instance', () async {
      final client = MozhiApiClient(
        baseUrl: Uri.parse('http://me:pw@mozhi.example'),
        httpClient: MockClient((request) async {
          requests.add(request);
          return switch (requests.length) {
            1 => _redirect(301, '/v2/api/version'),
            2 => _redirect(301, 'https://mozhi.example/v2/api/version'),
            _ => _json(versionJson),
          };
        }),
      );

      await client.getVersion();

      expect(requests.map((r) => r.url.toString()), [
        'http://mozhi.example/api/version',
        'http://mozhi.example/v2/api/version',
        'https://mozhi.example/v2/api/version',
      ]);
      expect(requests[0].headers['authorization'], startsWith('Basic '));
      expect(requests[1].headers['authorization'], startsWith('Basic '));
      // https is another origin than the base URL's http.
      expect(requests[2].headers, isNot(contains('authorization')));
    });
  });
}
