import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

AnthropicClient _client(
  FakeServer server, {
  String baseUrl = 'https://api.anthropic.com/v1',
  String? apiKey = 'sk-ant-test',
}) => AnthropicClient(
  LlmEndpoint(
    provider: LlmProvider.anthropic,
    baseUrl: Uri.parse(baseUrl),
    apiKey: apiKey,
  ),
  httpClient: server.client,
);

LlmRequest _request([String model = 'claude-haiku-5-5']) => LlmRequest(
  model: model,
  messages: const [
    LlmMessage.system('You translate.'),
    LlmMessage.user('Hallo'),
    LlmMessage.assistant('Hello'),
    LlmMessage.system('Be brief.'),
    LlmMessage.user('Tschüss'),
  ],
);

(String, Object?) _textDelta(String text) => (
  'content_block_delta',
  {
    'type': 'content_block_delta',
    'index': 1,
    'delta': {'type': 'text_delta', 'text': text},
  },
);

String _stream(List<(String, Object?)> events) => namedSse([
  (
    'message_start',
    {
      'type': 'message_start',
      'message': {'id': 'msg_1', 'model': 'claude', 'content': <Object?>[]},
    },
  ),
  ...events,
]);

String get _done => namedSse([
  (
    'message_delta',
    {
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
    },
  ),
  ('message_stop', {'type': 'message_stop'}),
]);

void main() {
  group(AnthropicClient, () {
    group('streamChat request', () {
      test('posts the exact body and headers', () async {
        final server = FakeServer([FakeResponse.text(_done)]);
        await _client(server).streamChat(_request()).drain<void>();

        final request = server.lastRequest;
        expect(request.method, 'POST');
        expect(request.url, Uri.parse('https://api.anthropic.com/v1/messages'));
        expect(request.headers['x-api-key'], 'sk-ant-test');
        expect(request.headers['anthropic-version'], '2023-06-01');
        expect(request.headers['content-type'], 'application/json');
        expect(
          request.headers['anthropic-dangerous-direct-browser-access'],
          'true',
        );
        expect(request.headers.containsKey('anthropic-beta'), isFalse);
        expect(request.json, {
          'model': 'claude-haiku-5-5',
          'max_tokens': 64000,
          'stream': true,
          'system': 'You translate.\n\nBe brief.',
          'messages': [
            {'role': 'user', 'content': 'Hallo'},
            {'role': 'assistant', 'content': 'Hello'},
            {'role': 'user', 'content': 'Tschüss'},
          ],
        });
      });

      test('includes temperature, max_tokens and effort when set', () async {
        final server = FakeServer([FakeResponse.text(_done)]);
        await _client(server)
            .streamChat(
              _request().copyWith(
                temperature: 0.5,
                maxTokens: 2048,
                effort: 'xhigh',
                jsonOutput: true,
              ),
            )
            .drain<void>();
        expect(server.lastRequest.json, {
          'model': 'claude-haiku-5-5',
          'max_tokens': 2048,
          'stream': true,
          'system': anything,
          'messages': hasLength(3),
          'temperature': 0.5,
          'output_config': {'effort': 'xhigh'},
        });
      });

      test('omits system and x-api-key when absent', () async {
        final server = FakeServer([FakeResponse.text(_done)]);
        await _client(server, apiKey: null)
            .streamChat(
              const LlmRequest(
                model: 'claude-haiku-5-5',
                messages: [LlmMessage.system(' '), LlmMessage.user('Hi')],
              ),
            )
            .drain<void>();
        expect(server.lastRequest.json, isNot(contains('system')));
        expect(server.lastRequest.headers.containsKey('x-api-key'), isFalse);
      });

      test('places image blocks before the text block', () async {
        final server = FakeServer([FakeResponse.text(_done)]);
        await _client(server)
            .streamChat(
              const LlmRequest(
                model: 'claude-haiku-5-5',
                messages: [
                  LlmMessage.user(
                    'Translate the sign',
                    images: [
                      LlmImage(bytes: [1, 2, 3], mimeType: 'image/webp'),
                    ],
                  ),
                  LlmMessage.user(
                    '',
                    images: [
                      LlmImage(bytes: [4]),
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
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/webp',
                  'data': 'AQID',
                },
              },
              {'type': 'text', 'text': 'Translate the sign'},
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'BA==',
                },
              },
            ],
          },
        ]);
      });

      test('enables server-side fallback for the listed models', () async {
        for (final model in AnthropicClient.fallbackModels) {
          final server = FakeServer([FakeResponse.text(_done)]);
          await _client(server).streamChat(_request(model)).drain<void>();
          expect(
            server.lastRequest.headers['anthropic-beta'],
            'server-side-fallback-2026-07-01',
            reason: model,
          );
          expect(
            server.lastRequest.json,
            containsPair('fallbacks', 'default'),
            reason: model,
          );
        }
      });

      test('does not enable fallback for other models or hosts', () async {
        final cases = [
          ('https://api.anthropic.com/v1', 'claude-haiku-5-5'),
          ('https://api.anthropic.com/v1', 'claude-opus-5-5-fast'),
          ('https://proxy.example.com/v1', 'claude-opus-5-5'),
        ];
        for (final (baseUrl, model) in cases) {
          final server = FakeServer([FakeResponse.text(_done)]);
          await _client(
            server,
            baseUrl: baseUrl,
          ).streamChat(_request(model)).drain<void>();
          expect(
            server.lastRequest.headers.containsKey('anthropic-beta'),
            isFalse,
            reason: '$baseUrl $model',
          );
          expect(
            server.lastRequest.json,
            isNot(contains('fallbacks')),
            reason: '$baseUrl $model',
          );
        }
      });
    });

    group('streamChat response', () {
      final body = _stream([
        (
          'content_block_start',
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'thinking', 'thinking': ''},
          },
        ),
        (
          'content_block_delta',
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': 'hmm'},
          },
        ),
        (
          'content_block_delta',
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'signature_delta', 'signature': 'abc'},
          },
        ),
        ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
        _textDelta('Grüße, '),
        ('ping', {'type': 'ping'}),
        (
          'content_block_start',
          {
            'type': 'content_block_start',
            'index': 2,
            'content_block': {
              'type': 'fallback',
              'from': {'model': 'claude-opus-5-5'},
              'to': {'model': 'claude-opus-4-8'},
            },
          },
        ),
        _textDelta(''),
        _textDelta('世界 👋'),
      ]);

      test('yields text deltas for any chunk boundaries', () async {
        for (final size in awkwardChunkSizes) {
          final server = FakeServer([
            FakeResponse.text(
              '$body$_done${namedSse([_textDelta('after stop')])}',
              chunkSize: size,
            ),
          ]);
          expect(
            await _client(server).chat(_request()),
            'Grüße, 世界 👋',
            reason: 'chunk size $size',
          );
        }
      });

      test('falls back to the SSE event name when data has no type', () async {
        final server = FakeServer([
          FakeResponse.text(
            'event: content_block_delta\n'
            'data: {"delta":{"type":"text_delta","text":"ok"}}\n\n'
            'event: ping\ndata:\n\n'
            'data: [1]\n\n',
          ),
        ]);
        expect(await _client(server).chat(_request()), 'ok');
      });

      test('throws LlmRefusalException with the category', () async {
        final server = FakeServer([
          FakeResponse.text(
            _stream([
              _textDelta('Partial'),
              (
                'message_delta',
                {
                  'type': 'message_delta',
                  'delta': {
                    'stop_reason': 'refusal',
                    'stop_details': {'type': 'refusal', 'category': 'cyber'},
                  },
                },
              ),
              ('message_stop', {'type': 'message_stop'}),
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request()),
          emitsInOrder(<Object>[
            'Partial',
            emitsError(
              isA<LlmRefusalException>().having(
                (e) => e.category,
                'category',
                'cyber',
              ),
            ),
          ]),
        );
      });

      test('reads stop_details at the event level or not at all', () async {
        final cases = <Map<String, Object?>, String?>{
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'refusal'},
            'stop_details': {'category': 'bio'},
          }: 'bio',
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'refusal', 'stop_details': null},
          }: null,
        };
        for (final MapEntry(key: event, value: category) in cases.entries) {
          final server = FakeServer([
            FakeResponse.text(_stream([('message_delta', event)])),
          ]);
          await expectLater(
            _client(server).streamChat(_request()),
            emitsError(
              isA<LlmRefusalException>().having(
                (e) => e.category,
                'category',
                category,
              ),
            ),
          );
        }
      });

      test('maps error events to LlmApiException', () async {
        final cases = <String, int?>{
          'overloaded_error': 529,
          'rate_limit_error': 429,
          'api_error': 500,
          'brand_new_error': null,
        };
        for (final MapEntry(key: type, value: status) in cases.entries) {
          final server = FakeServer([
            FakeResponse.text(
              _stream([
                (
                  'error',
                  {
                    'type': 'error',
                    'error': {'type': type, 'message': 'Overloaded'},
                  },
                ),
              ]),
            ),
          ]);
          await expectLater(
            _client(server).streamChat(_request()),
            emitsError(
              isA<LlmApiException>()
                  .having((e) => e, 'type', isNot(isA<LlmRefusalException>()))
                  .having((e) => e.message, 'message', 'Overloaded')
                  .having((e) => e.statusCode, 'statusCode', status)
                  .having((e) => e.body, 'body', contains(type)),
            ),
            reason: type,
          );
        }
      });

      test('extracts the message from HTTP error bodies', () async {
        final server = FakeServer([
          FakeResponse.json({
            'type': 'error',
            'error': {
              'type': 'authentication_error',
              'message': 'invalid x-api-key',
            },
          }, statusCode: 401),
        ]);
        await expectLater(
          _client(server).streamChat(_request()),
          emitsError(
            isA<LlmApiException>()
                .having((e) => e.message, 'message', 'invalid x-api-key')
                .having((e) => e.isAuthError, 'isAuthError', isTrue),
          ),
        );
      });
    });

    group('retries', () {
      Map<String, Object?> error(String message) => {
        'type': 'error',
        'error': {'type': 'invalid_request_error', 'message': message},
      };

      test('retries once with 8192 max_tokens', () async {
        final server = FakeServer([
          FakeResponse.json(
            error('max_tokens: 64000 > 32000, the maximum for this model'),
            statusCode: 400,
          ),
          FakeResponse.text(_stream([_textDelta('ok')]) + _done),
        ]);
        expect(await _client(server).chat(_request()), 'ok');
        expect(server.requests, hasLength(2));
        expect(server.requests.first.json, containsPair('max_tokens', 64000));
        expect(server.requests.last.json, containsPair('max_tokens', 8192));
      });

      test('does not repeat the max_tokens retry', () async {
        final server = FakeServer([
          FakeResponse.json(error('max_tokens too large'), statusCode: 400),
          FakeResponse.json(error('max_tokens still large'), statusCode: 400),
        ]);
        await expectLater(
          _client(server).streamChat(_request()),
          emitsError(
            isA<LlmApiException>().having(
              (e) => e.message,
              'message',
              'max_tokens still large',
            ),
          ),
        );
        expect(server.requests, hasLength(2));
      });

      test('retries without fallbacks when they are rejected', () async {
        final server = FakeServer([
          FakeResponse.json(
            error('fallbacks: Extra inputs are not permitted'),
            statusCode: 400,
          ),
          FakeResponse.text(_done),
        ]);
        await _client(server)
            .streamChat(_request('claude-opus-5-5'))
            .drain<void>();
        expect(server.requests, hasLength(2));
        final retry = server.requests.last;
        expect(retry.json, isNot(contains('fallbacks')));
        expect(retry.headers.containsKey('anthropic-beta'), isFalse);
      });

      test('retries both problems in turn', () async {
        final server = FakeServer([
          FakeResponse.json(error('max_tokens: too large'), statusCode: 400),
          FakeResponse.json(
            error('Unexpected value(s) for the `anthropic-beta` header'),
            statusCode: 400,
          ),
          FakeResponse.text(_done),
        ]);
        await _client(server)
            .streamChat(_request('claude-fable-5-1'))
            .drain<void>();
        expect(server.requests, hasLength(3));
        expect(server.requests.last.json, containsPair('max_tokens', 8192));
        expect(server.requests.last.json, isNot(contains('fallbacks')));
      });

      test('does not retry other 400s or fallback errors without '
          'fallbacks', () async {
        for (final message in ['messages: empty', 'fallbacks: invalid']) {
          final server = FakeServer([
            FakeResponse.json(error(message), statusCode: 400),
          ]);
          await expectLater(
            _client(server).streamChat(_request()),
            emitsError(
              isA<LlmApiException>().having((e) => e.statusCode, 'status', 400),
            ),
          );
          expect(server.requests, hasLength(1));
        }
      });

      test('does not retry other statuses', () async {
        final server = FakeServer([
          FakeResponse.json(error('max_tokens'), statusCode: 413),
        ]);
        await expectLater(
          _client(server).streamChat(_request()),
          emitsError(isA<LlmApiException>()),
        );
        expect(server.requests, hasLength(1));
      });
    });

    group('listModels', () {
      test('gets {base}/models?limit=1000', () async {
        final server = FakeServer([
          FakeResponse.json({
            'data': [
              {
                'type': 'model',
                'id': 'claude-sonnet-5-5',
                'display_name': 'Claude Sonnet 5.5',
                'max_input_tokens': 1000000,
              },
              {'id': 'claude-haiku-4-5'},
              {'id': ''},
              'junk',
            ],
            'has_more': false,
          }),
        ]);
        final models = await _client(server).listModels();
        final request = server.lastRequest;
        expect(request.method, 'GET');
        expect(
          request.url,
          Uri.parse('https://api.anthropic.com/v1/models?limit=1000'),
        );
        expect(request.headers['x-api-key'], 'sk-ant-test');
        expect(request.headers['anthropic-version'], '2023-06-01');
        expect(
          request.headers['anthropic-dangerous-direct-browser-access'],
          'true',
        );
        expect(models.map((m) => m.id), [
          'claude-haiku-4-5',
          'claude-sonnet-5-5',
        ]);
        expect(models.first.displayName, isNull);
        expect(models.first.contextWindow, isNull);
        expect(models.last.label, 'Claude Sonnet 5.5');
        expect(models.last.contextWindow, 1000000);
      });

      test('rejects unexpected responses', () async {
        final server = FakeServer([FakeResponse.json(<Object?>[])]);
        await expectLater(
          _client(server).listModels(),
          throwsA(isA<LlmApiException>()),
        );
      });
    });
  });
}
