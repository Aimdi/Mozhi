import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

const _request = LlmRequest(model: 'm', messages: [LlmMessage.user('Hallo')]);

/// Retries at once, so that the tests do not wait.
const _immediate = LlmRetryPolicy(baseDelay: Duration.zero);

const Map<LlmProvider, String> _bases = {
  LlmProvider.openAiCompatible: 'https://api.example.com/v1',
  LlmProvider.anthropic: 'https://api.anthropic.com/v1',
  LlmProvider.gemini: 'https://generativelanguage.googleapis.com/v1beta',
  LlmProvider.ollama: 'http://localhost:11434',
};

LlmClient _client(
  LlmProvider provider,
  http.Client httpClient, {
  LlmRetryPolicy retryPolicy = _immediate,
  String apiKey = 'key',
}) => LlmClient(
  LlmEndpoint(
    provider: provider,
    baseUrl: Uri.parse(_bases[provider]!),
    apiKey: apiKey,
  ),
  httpClient: httpClient,
  timeout: const Duration(seconds: 5),
  retryPolicy: retryPolicy,
);

String _ndjson(List<Map<String, Object?>> lines) =>
    lines.map((line) => '${jsonEncode(line)}\n').join();

/// A complete response streaming [text], in [provider]'s wire format.
String _success(LlmProvider provider, [String text = 'Hi']) =>
    switch (provider) {
      LlmProvider.openAiCompatible => sse([
        {
          'choices': [
            {
              'delta': {'content': text},
            },
          ],
        },
        '[DONE]',
      ]),
      LlmProvider.anthropic => namedSse([
        (
          'content_block_delta',
          {
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': text},
          },
        ),
        ('message_stop', {'type': 'message_stop'}),
      ]),
      LlmProvider.gemini => sse([
        {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': text},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        },
      ]),
      LlmProvider.ollama => _ndjson([
        {
          'message': {'content': text},
          'done': false,
        },
        {'done': true, 'done_reason': 'stop'},
      ]),
      LlmProvider.onDevice => throw UnsupportedError('No HTTP client'),
    };

/// Only the first text delta of [_success], without an end.
String _firstDelta(LlmProvider provider) {
  final full = _success(provider);
  return switch (provider) {
    LlmProvider.openAiCompatible ||
    LlmProvider.gemini => '${full.split('\n\n').first}\n\n',
    LlmProvider.anthropic => '${full.split('\n\n').first}\n\n',
    LlmProvider.ollama => '${full.split('\n').first}\n',
    LlmProvider.onDevice => throw UnsupportedError('No HTTP client'),
  };
}

/// An error event at the start of a 200 response that the provider maps to
/// a transient status (Ollama reports no status in its error lines).
const Map<LlmProvider, (String, int)> _errorEvents = {
  LlmProvider.openAiCompatible: (
    'data: {"error": {"code": 502, "message": "Upstream failed"}}\n\n',
    502,
  ),
  LlmProvider.anthropic: (
    'event: error\ndata: {"type": "error", "error": '
        '{"type": "overloaded_error", "message": "Overloaded"}}\n\n',
    529,
  ),
  LlmProvider.gemini: (
    'data: {"error": {"code": 503, "message": "The model is overloaded."}}'
        '\n\n',
    503,
  ),
};

Matcher _status(int status) =>
    isA<LlmApiException>().having((e) => e.statusCode, 'statusCode', status);

void main() {
  group('retries', () {
    test('a transient HTTP failure once, for every provider', () async {
      for (final provider in httpProviders) {
        for (final status in [429, 500, 502, 503, 504, 529]) {
          final server = FakeServer([
            FakeResponse.json({
              'error': {'message': 'busy'},
            }, statusCode: status),
            FakeResponse.text(_success(provider)),
          ]);
          final reason = '${provider.name} $status';
          expect(
            await _client(
              provider,
              server.client,
            ).streamChat(_request).toList(),
            ['Hi'],
            reason: reason,
          );
          final [first, second] = server.requests;
          expect(second.url, first.url, reason: reason);
          expect(second.body, first.body, reason: reason);
          expect(second.headers, first.headers, reason: reason);
          await expectLater(first.abortTrigger, completes, reason: reason);
        }
      }
    });

    test('an error event that arrives before any text', () async {
      for (final MapEntry(key: provider, value: (body, status))
          in _errorEvents.entries) {
        final server = FakeServer([
          FakeResponse.text(body),
          FakeResponse.text(_success(provider)),
        ]);
        expect(
          await _client(provider, server.client).streamChat(_request).toList(),
          ['Hi'],
          reason: '${provider.name} $status',
        );
        expect(server.requests, hasLength(2));
        await expectLater(server.requests.first.abortTrigger, completes);
      }
    });

    test('a connection dropped before any text', () async {
      for (final provider in httpProviders) {
        final server = FakeServer([
          FakeResponse(
            () => Stream.error(
              http.ClientException('Connection closed while receiving data'),
            ),
          ),
          // A body that ends without the end-of-response signal.
          FakeResponse.text(''),
          FakeResponse.text(_success(provider)),
        ]);
        final client = _client(
          provider,
          server.client,
          retryPolicy: const LlmRetryPolicy(
            maxRetries: 2,
            baseDelay: Duration.zero,
          ),
        );
        expect(await client.streamChat(_request).toList(), [
          'Hi',
        ], reason: provider.name);
        expect(server.requests, hasLength(3), reason: provider.name);
      }
    });

    test('a connection reset while sending the request', () async {
      var calls = 0;
      final client = _client(
        LlmProvider.openAiCompatible,
        MockClient.streaming((request, body) async {
          await body.drain<void>();
          if (calls++ == 0) {
            throw http.ClientException('Connection reset by peer');
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(_success(LlmProvider.openAiCompatible))),
            200,
          );
        }),
      );
      expect(await client.streamChat(_request).toList(), ['Hi']);
      expect(calls, 2);
    });

    test('with the wait the server asked for, by default', () async {
      final server = FakeServer([
        FakeResponse.text(
          '',
          statusCode: 503,
          headers: {'retry-after-ms': '200'},
        ),
        FakeResponse.text(_success(LlmProvider.anthropic)),
      ]);
      final client = LlmClient(
        LlmEndpoint(
          provider: LlmProvider.anthropic,
          baseUrl: Uri.parse(_bases[LlmProvider.anthropic]!),
          apiKey: 'key',
        ),
        httpClient: server.client,
      );
      final stopwatch = Stopwatch()..start();
      expect(await client.streamChat(_request).toList(), ['Hi']);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
      );
      expect(server.requests, hasLength(2));
    });

    test(
      'as often as the policy allows, then reports the last error',
      () async {
        final server = FakeServer([
          FakeResponse.text('first', statusCode: 503),
          FakeResponse.text('second', statusCode: 502),
          FakeResponse.text('third', statusCode: 500),
        ]);
        await expectLater(
          _client(
            LlmProvider.gemini,
            server.client,
            retryPolicy: const LlmRetryPolicy(
              maxRetries: 2,
              baseDelay: Duration.zero,
            ),
          ).streamChat(_request),
          emitsInOrder(<Object>[
            emitsError(
              isA<LlmApiException>()
                  .having((e) => e.message, 'message', 'third')
                  .having((e) => e.statusCode, 'statusCode', 500),
            ),
            emitsDone,
          ]),
        );
        expect(server.requests, hasLength(3));
      },
    );

    test('keeps the wait when the key is redacted', () async {
      final server = FakeServer([
        FakeResponse.text(
          'Too many requests for key-123',
          statusCode: 429,
          headers: {'retry-after': '60'},
        ),
      ]);
      await expectLater(
        _client(
          LlmProvider.openAiCompatible,
          server.client,
          apiKey: 'key-123',
        ).streamChat(_request),
        emitsError(
          isA<LlmApiException>()
              .having((e) => e.message, 'message', contains('[redacted]'))
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(minutes: 1),
              ),
        ),
      );
    });
  });

  group('does not retry', () {
    test('once text was delivered', () async {
      for (final provider in httpProviders) {
        final server = FakeServer([
          FakeResponse(() async* {
            yield utf8.encode(_firstDelta(provider));
            throw http.ClientException('Connection reset by peer');
          }),
        ]);
        await expectLater(
          _client(provider, server.client).streamChat(_request),
          emitsInOrder(<Object>[
            'Hi',
            emitsError(
              isA<LlmInterruptedException>().having(
                (e) => e.partialText,
                'partialText',
                'Hi',
              ),
            ),
            emitsDone,
          ]),
          reason: provider.name,
        );
        expect(server.requests, hasLength(1), reason: provider.name);
      }
    });

    test('an error event after text', () async {
      final server = FakeServer([
        FakeResponse.text(
          '${_firstDelta(LlmProvider.openAiCompatible)}'
          '${_errorEvents[LlmProvider.openAiCompatible]!.$1}',
        ),
      ]);
      await expectLater(
        _client(
          LlmProvider.openAiCompatible,
          server.client,
        ).streamChat(_request),
        emitsInOrder(<Object>['Hi', emitsError(_status(502))]),
      );
      expect(server.requests, hasLength(1));
    });

    test('permanent failures', () async {
      for (final status in [400, 401, 403, 404, 413, 501]) {
        final server = FakeServer([
          FakeResponse.text('nope', statusCode: status),
        ]);
        await expectLater(
          _client(LlmProvider.ollama, server.client).streamChat(_request),
          emitsError(_status(status)),
          reason: '$status',
        );
        expect(server.requests, hasLength(1), reason: '$status');
      }
    });

    test('exhausted credit', () async {
      final server = FakeServer([
        FakeResponse.json({
          'error': {
            'message': 'You exceeded your current quota.',
            'code': 'insufficient_quota',
          },
        }, statusCode: 429),
      ]);
      await expectLater(
        _client(
          LlmProvider.openAiCompatible,
          server.client,
        ).streamChat(_request),
        emitsError(_status(429)),
      );
      expect(server.requests, hasLength(1));
    });

    test('refused connections and failed lookups', () async {
      for (final message in [
        'Connection refused',
        "Failed host lookup: 'api.example.com'",
        'Use https for public servers: plain http is only allowed ...',
      ]) {
        var calls = 0;
        final client = _client(
          LlmProvider.openAiCompatible,
          MockClient.streaming((_, _) {
            calls++;
            throw http.ClientException(message);
          }),
        );
        await expectLater(
          client.streamChat(_request),
          emitsError(
            isA<LlmApiException>().having(
              (e) => e.connectionDropped,
              'connectionDropped',
              isFalse,
            ),
          ),
          reason: message,
        );
        expect(calls, 1, reason: message);
      }
    });

    test('when the server asks for a long wait', () async {
      final server = FakeServer([
        FakeResponse.text(
          'slow down',
          statusCode: 429,
          headers: {'Retry-After': '60'},
        ),
      ]);
      await expectLater(
        _client(LlmProvider.gemini, server.client).streamChat(_request),
        emitsError(
          isA<LlmApiException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(minutes: 1),
          ),
        ),
      );
      expect(server.requests, hasLength(1));
    });

    test('with LlmRetryPolicy.none', () async {
      final server = FakeServer([FakeResponse.text('', statusCode: 503)]);
      await expectLater(
        _client(
          LlmProvider.anthropic,
          server.client,
          retryPolicy: LlmRetryPolicy.none,
        ).streamChat(_request),
        emitsError(_status(503)),
      );
      expect(server.requests, hasLength(1));
    });

    test('model listings', () async {
      final server = FakeServer([FakeResponse.text('', statusCode: 503)]);
      await expectLater(
        _client(LlmProvider.ollama, server.client).listModels(),
        throwsA(_status(503)),
      );
      expect(server.requests, hasLength(1));
    });
  });

  group('cancellation', () {
    test('during the wait ends it at once, without another request', () async {
      final server = FakeServer([
        FakeResponse.text('', statusCode: 503),
        FakeResponse.text(_success(LlmProvider.openAiCompatible)),
      ]);
      final received = <Object>[];
      final subscription = _client(
        LlmProvider.openAiCompatible,
        server.client,
        retryPolicy: const LlmRetryPolicy(baseDelay: Duration(minutes: 5)),
      ).streamChat(_request).listen(received.add, onError: received.add);
      await pumpEventQueue();
      expect(server.requests, hasLength(1));

      final stopwatch = Stopwatch()..start();
      await subscription.cancel();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.requests, hasLength(1));
      expect(received, isEmpty);
    });

    test('during the retried request aborts it', () async {
      final gate = Completer<void>();
      final server = FakeServer([
        FakeResponse.text('', statusCode: 503),
        FakeResponse.text(
          _success(LlmProvider.openAiCompatible),
          gate: gate.future,
        ),
      ]);
      final received = <Object>[];
      final subscription = _client(
        LlmProvider.openAiCompatible,
        server.client,
      ).streamChat(_request).listen(received.add, onError: received.add);
      await pumpEventQueue();
      expect(server.requests, hasLength(2));

      await subscription.cancel();
      await expectLater(server.lastRequest.abortTrigger, completes);
      gate.complete();
      await pumpEventQueue();
      expect(received, isEmpty);
    });

    test('ignores a failure that arrives after cancelling', () async {
      final gate = Completer<void>();
      final server = FakeServer([
        FakeResponse.text('', statusCode: 503, gate: gate.future),
      ]);
      final received = <Object>[];
      final subscription = _client(
        LlmProvider.gemini,
        server.client,
      ).streamChat(_request).listen(received.add, onError: received.add);
      await pumpEventQueue();
      await subscription.cancel();
      gate.complete();
      await pumpEventQueue();
      expect(server.requests, hasLength(1));
      expect(received, isEmpty);
    });

    test('a retry made while paused waits for resume', () async {
      final server = FakeServer([
        FakeResponse.text('', statusCode: 503),
        FakeResponse.text(_success(LlmProvider.ollama)),
      ]);
      final received = <String>[];
      final done = Completer<void>();
      final subscription =
          _client(
              LlmProvider.ollama,
              server.client,
            ).streamChat(_request).listen(received.add, onDone: done.complete)
            ..pause();
      await pumpEventQueue();
      expect(server.requests, hasLength(2));
      expect(received, isEmpty);
      subscription.resume();
      await done.future;
      expect(received, ['Hi']);
      await subscription.cancel();
    });

    test('pausing during the wait holds the retried stream', () async {
      final server = FakeServer([
        FakeResponse.text('', statusCode: 503),
        FakeResponse.text(_success(LlmProvider.openAiCompatible)),
      ]);
      final received = <String>[];
      final done = Completer<void>();
      final subscription = _client(
        LlmProvider.openAiCompatible,
        server.client,
        retryPolicy: const LlmRetryPolicy(
          baseDelay: Duration(milliseconds: 20),
        ),
      ).streamChat(_request).listen(received.add, onDone: done.complete);
      await pumpEventQueue();
      subscription.pause();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(server.requests, hasLength(2));
      expect(received, isEmpty);
      subscription.resume();
      await done.future;
      expect(received, ['Hi']);
      await subscription.cancel();
    });
  });
}
