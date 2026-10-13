import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

const _request = LlmRequest(model: 'gpt', messages: [LlmMessage.user('Hi')]);

List<int> _delta(String text) => utf8.encode(
  sse([
    {
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    },
  ]),
);

OpenAiCompatibleClient _client(
  http.Client httpClient, {
  String baseUrl = 'https://api.example.com/v1',
  String? apiKey,
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 5),
}) => OpenAiCompatibleClient(
  LlmEndpoint(
    provider: LlmProvider.openAiCompatible,
    baseUrl: Uri.parse(baseUrl),
    apiKey: apiKey,
    headers: headers,
  ),
  httpClient: httpClient,
  timeout: timeout,
);

Matcher _apiException({
  Object? message = anything,
  Object? statusCode = anything,
  Object? body = anything,
}) => isA<LlmApiException>()
    .having((e) => e.message, 'message', message)
    .having((e) => e.statusCode, 'statusCode', statusCode)
    .having((e) => e.body, 'body', body);

void main() {
  group('HttpLlmClient', () {
    group('urls and headers', () {
      test('appends paths to a base URL with a trailing slash', () async {
        final server = FakeServer([
          FakeResponse.text(sse(['[DONE]'])),
        ]);
        await _client(
          server.client,
          baseUrl: 'https://api.example.com/v1/',
        ).streamChat(_request).drain<void>();
        expect(
          server.lastRequest.url,
          Uri.parse('https://api.example.com/v1/chat/completions'),
        );
      });

      test('keeps the query of the base URL', () async {
        final server = FakeServer([
          FakeResponse.json({'data': <Object?>[]}),
        ]);
        await _client(
          server.client,
          baseUrl: 'https://host.example/openai?api-version=2024-10-01',
        ).listModels();
        expect(
          server.lastRequest.url,
          Uri.parse(
            'https://host.example/openai/models?api-version=2024-10-01',
          ),
        );
      });

      test('sends endpoint headers last so they can override', () async {
        final server = FakeServer([
          FakeResponse.text(sse(['[DONE]'])),
          FakeResponse.json({'data': <Object?>[]}),
        ]);
        final client = _client(
          server.client,
          headers: {'X-Title': 'Mozhi', 'accept': 'text/plain'},
        );
        await client.streamChat(_request).drain<void>();
        await client.listModels();
        for (final request in server.requests) {
          expect(request.headers['x-title'], 'Mozhi');
        }
        expect(server.requests.first.headers['Accept'], 'text/plain');
      });
    });

    group('timeouts', () {
      test('fails when no response arrives in time and aborts', () async {
        final server = FakeServer([
          FakeResponse.text('', gate: Completer<void>().future),
        ]);
        final client = _client(
          server.client,
          timeout: const Duration(milliseconds: 50),
        );
        await expectLater(
          client.streamChat(_request),
          emitsError(
            _apiException(
              message: 'No response from api.example.com within 50 ms.',
              statusCode: isNull,
            ),
          ),
        );
        await expectLater(server.lastRequest.abortTrigger, completes);
      });

      test('describes whole-second timeouts in seconds', () async {
        final server = FakeServer([
          FakeResponse.text('', gate: Completer<void>().future),
        ]);
        await expectLater(
          _client(
            server.client,
            timeout: const Duration(seconds: 1),
          ).streamChat(_request),
          emitsError(_apiException(message: endsWith('within 1 s.'))),
        );
      });

      test('fails when the stream goes idle and aborts', () async {
        final body = StreamController<List<int>>();
        final server = FakeServer([FakeResponse.controlled(body)]);
        final client = _client(
          server.client,
          timeout: const Duration(milliseconds: 100),
        );
        final stream = client.streamChat(_request);
        body.add(_delta('A'));
        await expectLater(
          stream,
          emitsInOrder(<Object>[
            'A',
            emitsError(
              _apiException(
                message: contains('stopped responding (no data for 100 ms)'),
              ),
            ),
            emitsDone,
          ]),
        );
        await expectLater(server.lastRequest.abortTrigger, completes);
        expect(body.hasListener, isFalse);
      });

      test('keeps streaming while chunks arrive within the timeout', () async {
        final body = StreamController<List<int>>();
        final server = FakeServer([FakeResponse.controlled(body)]);
        final client = _client(
          server.client,
          timeout: const Duration(milliseconds: 200),
        );
        final output = client.streamChat(_request).join();
        for (final text in ['a', 'b', 'c']) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          body.add(_delta(text));
        }
        body.add(utf8.encode(sse(['[DONE]'])));
        expect(await output, 'abc');
      });

      test('listModels fails when no response arrives in time', () async {
        final server = FakeServer([
          FakeResponse.text('', gate: Completer<void>().future),
        ]);
        final client = _client(
          server.client,
          timeout: const Duration(milliseconds: 50),
        );
        await expectLater(
          client.listModels(),
          throwsA(_apiException(message: contains('No response'))),
        );
        await expectLater(server.lastRequest.abortTrigger, completes);
      });

      test('listModels fails when the body stalls', () async {
        final body = StreamController<List<int>>()..add(utf8.encode('{"da'));
        final server = FakeServer([FakeResponse.controlled(body)]);
        final client = _client(
          server.client,
          timeout: const Duration(milliseconds: 50),
        );
        await expectLater(
          client.listModels(),
          throwsA(_apiException(message: contains('stopped responding'))),
        );
        expect(body.hasListener, isFalse);
      });
    });

    group('cancellation', () {
      test('cancelling while streaming aborts the request', () async {
        final body = StreamController<List<int>>();
        var bodyCancelled = false;
        body.onCancel = () => bodyCancelled = true;
        final server = FakeServer([FakeResponse.controlled(body)]);
        final client = _client(server.client);

        final first = Completer<String>();
        final subscription = client.streamChat(_request).listen(first.complete);
        body.add(_delta('partial'));
        expect(await first.future, 'partial');

        await subscription.cancel();
        await expectLater(server.lastRequest.abortTrigger, completes);
        expect(bodyCancelled, isTrue);
      });

      test(
        'cancelling while connecting aborts and releases the response',
        () async {
          final gate = Completer<void>();
          final body = StreamController<List<int>>();
          var bodyCancelled = false;
          body.onCancel = () => bodyCancelled = true;
          final server = FakeServer([
            FakeResponse(() => body.stream, gate: gate.future),
          ]);
          final client = _client(server.client);

          final received = <Object>[];
          final subscription = client
              .streamChat(_request)
              .listen(received.add, onError: received.add);
          await pumpEventQueue();
          expect(server.requests, hasLength(1));

          await subscription.cancel();
          await expectLater(server.lastRequest.abortTrigger, completes);

          gate.complete();
          await pumpEventQueue();
          expect(bodyCancelled, isTrue);
          expect(received, isEmpty);
        },
      );

      test('ignores failures that arrive after cancellation', () async {
        final gate = Completer<void>();
        final server = FakeServer([
          FakeResponse.text('{}', statusCode: 500, gate: gate.future),
        ]);
        final received = <Object>[];
        final subscription = _client(server.client)
            .streamChat(_request)
            .listen(received.add, onError: received.add);
        await pumpEventQueue();
        await subscription.cancel();
        gate.complete();
        await pumpEventQueue();
        expect(received, isEmpty);
      });

      test('honours pause and resume', () async {
        final gate = Completer<void>();
        final server = FakeServer([
          FakeResponse.text(
            sse([
              {
                'choices': [
                  {
                    'delta': {'content': 'x'},
                  },
                ],
              },
              '[DONE]',
            ]),
            gate: gate.future,
          ),
        ]);
        final received = <String>[];
        final done = Completer<void>();
        final subscription =
            _client(server.client)
                .streamChat(_request)
                .listen(received.add, onDone: done.complete)
              ..pause();
        gate.complete();
        await pumpEventQueue();
        expect(received, isEmpty);

        subscription
          ..resume()
          ..pause();
        await pumpEventQueue();
        subscription.resume();
        await done.future;
        expect(received, ['x']);
        await subscription.cancel();
      });

      test('completes the abort trigger once the stream ends', () async {
        final server = FakeServer([
          FakeResponse.text(sse(['[DONE]'])),
        ]);
        await _client(server.client).streamChat(_request).drain<void>();
        await expectLater(server.lastRequest.abortTrigger, completes);
      });
    });

    group('errors', () {
      Future<LlmApiException> httpFailure(
        String body, {
        int statusCode = 400,
        String? reasonPhrase,
        String? apiKey,
      }) async {
        final server = FakeServer([
          FakeResponse.text(
            body,
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
          ),
        ]);
        try {
          await _client(
            server.client,
            apiKey: apiKey,
          ).streamChat(_request).drain<void>();
        } on LlmApiException catch (error) {
          return error;
        }
        fail('expected an LlmApiException');
      }

      test('extracts the message from JSON error bodies', () async {
        final bodies = {
          jsonEncode({
            'error': {'message': 'Incorrect API key', 'type': 'auth'},
          }): 'Incorrect API key',
          jsonEncode({'error': 'model "x" not found'}): 'model "x" not found',
          jsonEncode({'message': 'Too many requests'}): 'Too many requests',
          jsonEncode({'detail': 'Not allowed'}): 'Not allowed',
          jsonEncode({
            'detail': [
              {'loc': <Object?>[], 'msg': 'field required'},
            ],
          }): 'field required',
          jsonEncode([
            {
              'error': {'message': ' list form '},
            },
          ]): 'list form',
          jsonEncode({'unexpected': 1}): '{"unexpected":1}',
          '  Service unavailable \n': 'Service unavailable',
        };
        for (final MapEntry(key: body, value: message) in bodies.entries) {
          expect(
            await httpFailure(body),
            _apiException(message: message, statusCode: 400, body: body),
            reason: body,
          );
        }
      });

      test('truncates long plain-text messages and bodies', () async {
        final body = 'x' * 3000;
        final error = await httpFailure(body, statusCode: 502);
        expect(error.message, hasLength(300));
        expect(error.message, endsWith('…'));
        expect(error.body, hasLength(2000));
      });

      test('prefers the reason phrase over HTML or empty bodies', () async {
        expect(
          await httpFailure(
            '<html><body>502</body></html>',
            statusCode: 502,
            reasonPhrase: 'Bad Gateway',
          ),
          _apiException(message: 'Bad Gateway', statusCode: 502),
        );
        expect(
          await httpFailure('', statusCode: 404, reasonPhrase: 'Not Found'),
          _apiException(message: 'Not Found', body: isNull),
        );
        expect(
          await httpFailure('', statusCode: 500),
          _apiException(message: 'HTTP 500'),
        );
      });

      test('classifies status codes', () async {
        expect((await httpFailure('', statusCode: 401)).isAuthError, isTrue);
        expect((await httpFailure('', statusCode: 403)).isAuthError, isTrue);
        expect((await httpFailure('', statusCode: 429)).isRateLimited, isTrue);
        expect((await httpFailure('', statusCode: 404)).isNotFound, isTrue);
      });

      test('falls back to the reason phrase when the body fails', () async {
        final server = FakeServer([
          FakeResponse(
            () => Stream.error(http.ClientException('reset')),
            statusCode: 503,
            reasonPhrase: 'Service Unavailable',
          ),
        ]);
        await expectLater(
          _client(server.client).streamChat(_request),
          emitsError(
            _apiException(message: 'Service Unavailable', statusCode: 503),
          ),
        );
      });

      test('never exposes the API key', () async {
        const key = 'sk-secret-123';
        final error = await httpFailure(
          jsonEncode({
            'error': {'message': 'Invalid key $key'},
          }),
          statusCode: 401,
          apiKey: key,
        );
        expect(error.message, 'Invalid key [redacted]');
        expect(error.body, isNot(contains(key)));
        expect(error.statusCode, 401);
        expect(error.toString(), isNot(contains(key)));
      });

      test('maps transport errors', () async {
        final client = _client(
          MockClient.streaming(
            (_, _) => throw http.ClientException('Connection refused'),
          ),
        );
        await expectLater(
          client.streamChat(_request),
          emitsError(
            _apiException(
              message: 'Could not reach api.example.com: Connection refused',
              statusCode: isNull,
            ),
          ),
        );
        await expectLater(
          client.listModels(),
          throwsA(_apiException(message: contains('Connection refused'))),
        );
      });

      test('maps unexpected errors', () async {
        final client = _client(
          MockClient.streaming((_, _) => throw StateError('boom')),
        );
        await expectLater(
          client.streamChat(_request),
          emitsError(
            _apiException(message: 'Unexpected error: Bad state: boom'),
          ),
        );
      });

      test('maps malformed stream data', () async {
        final server = FakeServer([FakeResponse.text('data: {oops\n\n')]);
        await expectLater(
          _client(server.client).streamChat(_request),
          emitsError(
            _apiException(
              message: startsWith('The server sent malformed data'),
              body: '{oops',
            ),
          ),
        );
      });

      test('maps malformed JSON responses', () async {
        final server = FakeServer([FakeResponse.text('not json')]);
        await expectLater(
          _client(server.client).listModels(),
          throwsA(_apiException(message: contains('malformed'))),
        );
      });

      test('ends the stream and aborts after an error', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              {
                'error': {'message': 'boom'},
              },
              {
                'choices': [
                  {
                    'delta': {'content': 'never'},
                  },
                ],
              },
            ]),
          ),
        ]);
        await expectLater(
          _client(server.client).streamChat(_request),
          emitsInOrder(<Object>[emitsError(isA<LlmApiException>()), emitsDone]),
        );
        await expectLater(server.lastRequest.abortTrigger, completes);
      });
    });
  });
}
