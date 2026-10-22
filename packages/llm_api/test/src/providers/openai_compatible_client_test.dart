import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

OpenAiCompatibleClient _client(
  FakeServer server, {
  String? apiKey = 'sk-test',
  Map<String, String> headers = const {},
}) => OpenAiCompatibleClient(
  LlmEndpoint(
    provider: LlmProvider.openAiCompatible,
    baseUrl: Uri.parse('https://api.example.com/v1'),
    apiKey: apiKey,
    headers: headers,
  ),
  httpClient: server.client,
  retryPolicy: LlmRetryPolicy.none,
);

Map<String, Object?> _chunk(Map<String, Object?> delta, {String? finish}) => {
  'id': 'chatcmpl-1',
  'object': 'chat.completion.chunk',
  'choices': [
    {'index': 0, 'delta': delta, 'finish_reason': finish},
  ],
};

const _request = LlmRequest(
  model: 'gpt-test',
  messages: [
    LlmMessage.system('Translate.'),
    LlmMessage.user('Hallo'),
    LlmMessage.assistant('Hello'),
    LlmMessage.user('Tschüss'),
  ],
);

void main() {
  group(OpenAiCompatibleClient, () {
    group('streamChat request', () {
      test('posts the exact body and headers', () async {
        final server = FakeServer([
          FakeResponse.text(sse(['[DONE]'])),
        ]);
        await _client(
          server,
          headers: {'HTTP-Referer': 'https://mozhi.app'},
        ).streamChat(_request).drain<void>();

        final request = server.lastRequest;
        expect(request.method, 'POST');
        expect(
          request.url,
          Uri.parse('https://api.example.com/v1/chat/completions'),
        );
        expect(request.headers['content-type'], 'application/json');
        expect(request.headers['accept'], 'text/event-stream');
        expect(request.headers['authorization'], 'Bearer sk-test');
        expect(request.headers['http-referer'], 'https://mozhi.app');
        expect(request.json, {
          'model': 'gpt-test',
          'messages': [
            {'role': 'system', 'content': 'Translate.'},
            {'role': 'user', 'content': 'Hallo'},
            {'role': 'assistant', 'content': 'Hello'},
            {'role': 'user', 'content': 'Tschüss'},
          ],
          'stream': true,
        });
      });

      test('includes the optional parameters when set', () async {
        final server = FakeServer([
          FakeResponse.text(sse(['[DONE]'])),
        ]);
        await _client(server)
            .streamChat(
              _request.copyWith(
                temperature: 0.2,
                maxTokens: 100,
                effort: 'low',
                jsonOutput: true,
              ),
            )
            .drain<void>();
        expect(server.lastRequest.json, {
          'model': 'gpt-test',
          'messages': hasLength(4),
          'stream': true,
          'temperature': 0.2,
          'max_tokens': 100,
          'reasoning_effort': 'low',
          'response_format': {'type': 'json_object'},
        });
      });

      test('omits Authorization without a key', () async {
        for (final key in [null, '', '  ']) {
          final server = FakeServer([
            FakeResponse.text(sse(['[DONE]'])),
          ]);
          await _client(server, apiKey: key).streamChat(_request).drain<void>();
          expect(
            server.lastRequest.headers.containsKey('authorization'),
            isFalse,
          );
        }
      });

      test('trims the key', () async {
        final server = FakeServer([
          FakeResponse.text(sse(['[DONE]'])),
        ]);
        await _client(
          server,
          apiKey: ' sk-x\n',
        ).streamChat(_request).drain<void>();
        expect(server.lastRequest.headers['authorization'], 'Bearer sk-x');
      });

      test('encodes images as data URL content parts', () async {
        final server = FakeServer([
          FakeResponse.text(sse(['[DONE]'])),
        ]);
        await _client(server)
            .streamChat(
              const LlmRequest(
                model: 'vision',
                messages: [
                  LlmMessage.user(
                    'What does it say?',
                    images: [
                      LlmImage(bytes: [1, 2, 3], mimeType: 'image/jpeg'),
                    ],
                  ),
                  LlmMessage.user(
                    '',
                    images: [
                      LlmImage(bytes: [255]),
                    ],
                  ),
                ],
              ),
            )
            .drain<void>();
        expect((server.lastRequest.json! as Map)['messages'], [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'What does it say?'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,AQID'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png;base64,/w=='},
              },
            ],
          },
        ]);
      });
    });

    group('streamChat response', () {
      final body = [
        ': OPENROUTER PROCESSING\r\n\r\n',
        sse([
          _chunk({'role': 'assistant', 'content': ''}),
          _chunk({'reasoning_content': 'hidden'}),
          _chunk({'reasoning': 'hidden'}),
          _chunk({'content': null}),
          _chunk({
            'tool_calls': [
              {'index': 0, 'function': <String, Object?>{}},
            ],
          }),
          _chunk({'content': 'Grüße, '}),
        ], crlf: true),
        'data:${jsonEncode(_chunk({'content': '世界 👋'}))}\n\n',
        sse([
          {'choices': <Object?>[]},
          [1, 2], // Valid JSON that is not an object is ignored.
          _chunk({}, finish: 'stop'),
          '[DONE]',
          _chunk({'content': 'after done'}),
        ]),
      ].join();

      test('yields content deltas for any chunk boundaries', () async {
        for (final size in awkwardChunkSizes) {
          final server = FakeServer([FakeResponse.text(body, chunkSize: size)]);
          expect(
            await _client(server)
                .streamChat(_request)
                .toList()
                .then((deltas) => deltas.join()),
            'Grüße, 世界 👋',
            reason: 'chunk size $size',
          );
        }
      });

      test('removes inline think blocks', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk({'content': '<thi'}),
              _chunk({'content': 'nk>Let me think</th'}),
              _chunk({'content': 'ink>\n\nBonjour'}),
              '[DONE]',
            ]),
          ),
        ]);
        expect(await _client(server).chat(_request), 'Bonjour');
      });

      test('completes at a finish_reason without [DONE]', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk({'content': 'ok'}, finish: 'stop'),
            ]),
          ),
        ]);
        expect(await _client(server).chat(_request), 'ok');
      });

      test('throws LlmInterruptedException when the stream ends without '
          '[DONE] or a finish_reason', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk({'content': 'Bonjour, '}),
              _chunk({'content': 'comment'}),
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsInOrder(<Object>[
            'Bonjour, ',
            'comment',
            emitsError(
              isA<LlmInterruptedException>()
                  .having(
                    (e) => e.message,
                    'message',
                    LlmInterruptedException.defaultMessage,
                  )
                  .having(
                    (e) => e.partialText,
                    'partialText',
                    'Bonjour, comment',
                  )
                  .having((e) => e.statusCode, 'statusCode', isNull),
            ),
            emitsDone,
          ]),
        );
      });

      test('throws LlmTruncatedException at finish_reason length', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk({'content': '<think>plan</think>Partial '}),
              _chunk({'content': 'para 1'}),
              _chunk({}, finish: 'length'),
              '[DONE]',
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsInOrder(<Object>[
            'Partial ',
            'para 1',
            emitsError(
              isA<LlmTruncatedException>()
                  .having(
                    (e) => e.message,
                    'message',
                    LlmTruncatedException.defaultMessage,
                  )
                  .having((e) => e.partialText, 'partialText', 'Partial para 1')
                  .having((e) => e.reason, 'reason', 'length'),
            ),
            emitsDone,
          ]),
        );
      });

      test('chat throws LlmTruncatedException with the partial text', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk({'content': 'Partial'}, finish: 'length'),
            ]),
          ),
        ]);
        await expectLater(
          _client(server).chat(_request),
          throwsA(
            isA<LlmTruncatedException>().having(
              (e) => e.partialText,
              'partialText',
              'Partial',
            ),
          ),
        );
      });

      test('throws an error chunk as LlmApiException', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk({'content': 'partial'}),
              {
                'error': {'code': 502, 'message': 'Upstream provider error'},
              },
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsInOrder(<Object>[
            'partial',
            emitsError(
              isA<LlmApiException>()
                  .having(
                    (e) => e.message,
                    'message',
                    'Upstream provider error',
                  )
                  .having((e) => e.statusCode, 'statusCode', 502)
                  .having((e) => e.body, 'body', contains('Upstream')),
            ),
          ]),
        );
      });

      test('uses a generic message for error chunks without one', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              {
                'error': {'code': 'server_error'},
              },
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsError(
            isA<LlmApiException>()
                .having(
                  (e) => e.message,
                  'message',
                  'The server reported an error.',
                )
                .having((e) => e.statusCode, 'statusCode', isNull),
          ),
        );
      });

      test('throws LlmRefusalException on content_filter', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk({'content': 'Some'}, finish: 'content_filter'),
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsInOrder(<Object>[
            'Some',
            emitsError(
              isA<LlmRefusalException>().having(
                (e) => e.category,
                'category',
                'content_filter',
              ),
            ),
          ]),
        );
      });
    });

    group('retries', () {
      final options = _request.copyWith(jsonOutput: true, effort: 'high');

      test('retries once without unsupported options on 400', () async {
        final server = FakeServer([
          FakeResponse.json({
            'error': {
              'message': "Unrecognized request argument: 'reasoning_effort'",
            },
          }, statusCode: 400),
          FakeResponse.text(
            sse([
              _chunk({'content': 'ok'}),
              '[DONE]',
            ]),
          ),
        ]);
        expect(await _client(server).chat(options), 'ok');
        expect(server.requests, hasLength(2));
        expect(
          server.requests.first.json,
          containsPair('reasoning_effort', 'high'),
        );
        final retried = server.requests.last.json! as Map<String, Object?>;
        expect(retried.containsKey('reasoning_effort'), isFalse);
        expect(retried.containsKey('response_format'), isFalse);
        expect(retried['model'], 'gpt-test');
      });

      test('retries when only jsonOutput was sent', () async {
        final server = FakeServer([
          FakeResponse.json({'detail': 'response_format'}, statusCode: 400),
          FakeResponse.text(sse(['[DONE]'])),
        ]);
        await _client(server)
            .streamChat(_request.copyWith(jsonOutput: true))
            .drain<void>();
        expect(server.requests, hasLength(2));
      });

      test('reports the second failure when the retry fails', () async {
        final server = FakeServer([
          FakeResponse.json({'error': 'first'}, statusCode: 400),
          FakeResponse.json({'error': 'second'}, statusCode: 400),
        ]);
        await expectLater(
          _client(server).streamChat(options),
          emitsError(
            isA<LlmApiException>().having(
              (e) => e.message,
              'message',
              'second',
            ),
          ),
        );
        expect(server.requests, hasLength(2));
      });

      test('does not retry when no optional parameter was sent', () async {
        final server = FakeServer([
          FakeResponse.json({'error': 'context too long'}, statusCode: 400),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsError(
            isA<LlmApiException>()
                .having((e) => e.message, 'message', 'context too long')
                .having((e) => e.statusCode, 'statusCode', 400),
          ),
        );
        expect(server.requests, hasLength(1));
      });

      test('does not retry other statuses', () async {
        final server = FakeServer([
          FakeResponse.json({'error': 'bad key'}, statusCode: 401),
        ]);
        await expectLater(
          _client(server).streamChat(options),
          emitsError(
            isA<LlmApiException>().having((e) => e.isAuthError, 'auth', isTrue),
          ),
        );
        expect(server.requests, hasLength(1));
      });
    });

    group('listModels', () {
      test('gets {base}/models and sorts by id', () async {
        final server = FakeServer([
          FakeResponse.json({
            'object': 'list',
            'data': [
              {'id': 'b-model', 'object': 'model'},
              {'id': 'a-model', 'name': 'Model A', 'context_length': 8192},
              {'id': 'c-model', 'name': 'c-model', 'context_window': 4096},
              {'id': 'b-model'},
              {'id': ''},
              42,
            ],
          }),
        ]);
        final models = await _client(server).listModels();
        expect(server.lastRequest.method, 'GET');
        expect(
          server.lastRequest.url,
          Uri.parse('https://api.example.com/v1/models'),
        );
        expect(server.lastRequest.headers['authorization'], 'Bearer sk-test');
        expect(models.map((m) => m.id), ['a-model', 'b-model', 'c-model']);
        expect(models.first.displayName, 'Model A');
        expect(models.first.contextWindow, 8192);
        expect(models[1].displayName, isNull);
        expect(models.last.displayName, isNull);
        expect(models.last.contextWindow, 4096);
      });

      test('accepts a bare list and {"models": [...]}', () async {
        final server = FakeServer([
          FakeResponse.json([
            'local-model',
            '',
            {'id': 'other', 'max_model_len': 32768},
          ]),
          FakeResponse.json({
            'models': [
              {'name': 'llama3:8b', 'max_context_length': 8192},
              {'model': 'ignored'},
            ],
          }),
        ]);
        final client = _client(server);
        final bare = await client.listModels();
        expect(bare.map((m) => m.id), ['local-model', 'other']);
        expect(bare.last.contextWindow, 32768);
        final wrapped = await client.listModels();
        expect(wrapped.single.id, 'llama3:8b');
        expect(wrapped.single.contextWindow, 8192);
      });

      test('rejects unexpected responses', () async {
        final server = FakeServer([
          FakeResponse.json({'object': 'list'}),
        ]);
        await expectLater(
          _client(server).listModels(),
          throwsA(isA<LlmApiException>()),
        );
      });

      test('reports HTTP errors', () async {
        final server = FakeServer([
          FakeResponse.json({
            'error': {'message': 'Invalid token'},
          }, statusCode: 401),
        ]);
        await expectLater(
          _client(server).listModels(),
          throwsA(
            isA<LlmApiException>()
                .having((e) => e.message, 'message', 'Invalid token')
                .having((e) => e.isAuthError, 'isAuthError', isTrue),
          ),
        );
      });
    });
  });
}
