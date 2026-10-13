import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

const _base = 'https://generativelanguage.googleapis.com/v1beta';

GeminiClient _client(FakeServer server, {String? apiKey = 'AIza-test'}) =>
    GeminiClient(
      LlmEndpoint(
        provider: LlmProvider.gemini,
        baseUrl: Uri.parse(_base),
        apiKey: apiKey,
      ),
      httpClient: server.client,
    );

const _request = LlmRequest(
  model: 'gemini-flash-latest',
  messages: [
    LlmMessage.system('You translate.'),
    LlmMessage.system('Be brief.'),
    LlmMessage.user('Hallo'),
    LlmMessage.assistant('Hello'),
    LlmMessage.user('Tschüss'),
  ],
);

Map<String, Object?> _chunk(
  List<Map<String, Object?>> parts, {
  String? finishReason,
}) => {
  'candidates': [
    {
      'content': {'role': 'model', 'parts': parts},
      'finishReason': ?finishReason,
    },
  ],
};

/// A response that only finishes.
final String _stop = sse([
  {
    'candidates': [
      {'finishReason': 'STOP'},
    ],
  },
]);

void main() {
  group(GeminiClient, () {
    group('streamChat request', () {
      test('posts the exact body and headers', () async {
        final server = FakeServer([FakeResponse.text(_stop)]);
        await _client(server).streamChat(_request).drain<void>();

        final request = server.lastRequest;
        expect(request.method, 'POST');
        expect(
          request.url,
          Uri.parse(
            '$_base/models/gemini-flash-latest:streamGenerateContent?alt=sse',
          ),
        );
        expect(request.headers['x-goog-api-key'], 'AIza-test');
        expect(request.headers['content-type'], 'application/json');
        expect(request.url.queryParameters, isNot(contains('key')));
        expect(request.json, {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': 'Hallo'},
              ],
            },
            {
              'role': 'model',
              'parts': [
                {'text': 'Hello'},
              ],
            },
            {
              'role': 'user',
              'parts': [
                {'text': 'Tschüss'},
              ],
            },
          ],
          'systemInstruction': {
            'parts': [
              {'text': 'You translate.\n\nBe brief.'},
            ],
          },
        });
      });

      test('sends generationConfig when options are set', () async {
        final server = FakeServer([FakeResponse.text(_stop)]);
        await _client(server)
            .streamChat(
              _request.copyWith(
                temperature: 0.3,
                maxTokens: 500,
                jsonOutput: true,
                effort: 'high',
              ),
            )
            .drain<void>();
        final json = server.lastRequest.json! as Map<String, Object?>;
        expect(json['generationConfig'], {
          'temperature': 0.3,
          'maxOutputTokens': 500,
          'responseMimeType': 'application/json',
        });
        expect(
          json.keys,
          unorderedEquals(<String>[
            'contents',
            'systemInstruction',
            'generationConfig',
          ]),
        );
      });

      test('omits systemInstruction and the key header when absent', () async {
        final server = FakeServer([FakeResponse.text(_stop)]);
        await _client(server, apiKey: null)
            .streamChat(
              const LlmRequest(
                model: 'gemini-flash-latest',
                messages: [LlmMessage.user('Hi')],
              ),
            )
            .drain<void>();
        expect(server.lastRequest.json, {
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': 'Hi'},
              ],
            },
          ],
        });
        expect(
          server.lastRequest.headers.containsKey('x-goog-api-key'),
          isFalse,
        );
      });

      test('adds images as inlineData parts after the text', () async {
        final server = FakeServer([FakeResponse.text(_stop)]);
        await _client(server)
            .streamChat(
              const LlmRequest(
                model: 'gemini-flash-latest',
                messages: [
                  LlmMessage.user(
                    'Read this',
                    images: [
                      LlmImage(bytes: [1, 2, 3], mimeType: 'image/jpeg'),
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
        expect((server.lastRequest.json! as Map)['contents'], [
          {
            'role': 'user',
            'parts': [
              {'text': 'Read this'},
              {
                'inlineData': {'mimeType': 'image/jpeg', 'data': 'AQID'},
              },
            ],
          },
          {
            'role': 'user',
            'parts': [
              {
                'inlineData': {'mimeType': 'image/png', 'data': 'BA=='},
              },
            ],
          },
        ]);
      });

      test('keeps resource names that already contain a slash', () async {
        for (final model in ['models/gemini-pro', 'tunedModels/my-model']) {
          final server = FakeServer([FakeResponse.text(_stop)]);
          await _client(server)
              .streamChat(_request.copyWith(model: model))
              .drain<void>();
          expect(
            server.lastRequest.url.path,
            '/v1beta/$model:streamGenerateContent',
          );
        }
      });
    });

    group('streamChat response', () {
      final body = sse([
        _chunk([
          {'text': 'Thinking about it', 'thought': true},
          {'text': 'Grüße, '},
        ]),
        {
          'candidates': <Object?>[],
          'usageMetadata': {'promptTokenCount': 3},
        },
        _chunk([
          {'text': ''},
          {'thoughtSignature': 'abc'},
          {'text': '世界 '},
          {'text': '👋', 'thought': false},
        ]),
        {
          'candidates': [
            {'finishReason': 'STOP'},
          ],
        },
        [1, 2],
      ]);

      test('yields non-thought text parts for any chunk boundaries', () async {
        for (final size in awkwardChunkSizes) {
          final server = FakeServer([
            FakeResponse.text('$body\n', chunkSize: size),
          ]);
          expect(
            await _client(server).chat(_request),
            'Grüße, 世界 👋',
            reason: 'chunk size $size',
          );
        }
      });

      test('throws LlmRefusalException for blocking finish reasons', () async {
        for (final reason in GeminiClient.refusalFinishReasons) {
          final server = FakeServer([
            FakeResponse.text(
              sse([
                _chunk([
                  {'text': 'Partial'},
                ], finishReason: reason),
              ]),
            ),
          ]);
          await expectLater(
            _client(server).streamChat(_request),
            emitsInOrder(<Object>[
              'Partial',
              emitsError(
                isA<LlmRefusalException>().having(
                  (e) => e.category,
                  'category',
                  reason,
                ),
              ),
            ]),
            reason: reason,
          );
        }
      });

      test('throws LlmTruncatedException at MAX_TOKENS', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              _chunk([
                {'text': 'Partial '},
              ]),
              _chunk([
                {'text': 'para 1'},
              ], finishReason: 'MAX_TOKENS'),
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
                  .having((e) => e.reason, 'reason', 'MAX_TOKENS')
                  .having(
                    (e) => e.partialText,
                    'partialText',
                    'Partial para 1',
                  ),
            ),
          ]),
        );
      });

      test('throws LlmApiException for an unsupported language', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              {
                'candidates': [
                  {'finishReason': 'LANGUAGE'},
                ],
              },
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsError(
            isA<LlmApiException>()
                .having((e) => e, 'type', isNot(isA<LlmRefusalException>()))
                .having(
                  (e) => e.message,
                  'message',
                  'Gemini does not support this language.',
                ),
          ),
        );
      });

      test('throws LlmApiException for other finish reasons', () async {
        for (final reason in [
          'OTHER',
          'FINISH_REASON_UNSPECIFIED',
          'MALFORMED_FUNCTION_CALL',
        ]) {
          final server = FakeServer([
            FakeResponse.text(
              sse([
                _chunk([
                  {'text': 'Partial'},
                ], finishReason: reason),
              ]),
            ),
          ]);
          await expectLater(
            _client(server).streamChat(_request),
            emitsInOrder(<Object>[
              'Partial',
              emitsError(
                isA<LlmApiException>()
                    .having((e) => e, 'type', isNot(isA<LlmRefusalException>()))
                    .having(
                      (e) => e.message,
                      'message',
                      'Gemini stopped without completing the response '
                          '($reason).',
                    ),
              ),
            ]),
            reason: reason,
          );
        }
      });

      test('throws LlmInterruptedException without a finish reason', () async {
        for (final body in [
          '',
          sse([
            _chunk([
              {'text': 'Bonjour'},
            ]),
          ]),
        ]) {
          final server = FakeServer([FakeResponse.text(body)]);
          await expectLater(
            _client(server).streamChat(_request).join(),
            throwsA(
              isA<LlmInterruptedException>().having(
                (e) => e.partialText,
                'partialText',
                body.isEmpty ? '' : 'Bonjour',
              ),
            ),
          );
        }
      });

      test('throws LlmRefusalException for a blocked prompt', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              {
                'promptFeedback': {'blockReason': 'PROHIBITED_CONTENT'},
              },
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsError(
            isA<LlmRefusalException>()
                .having((e) => e.category, 'category', 'PROHIBITED_CONTENT')
                .having((e) => e.message, 'message', contains('blocked')),
          ),
        );
      });

      test('never exposes the API key, even in a refusal', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              {
                'promptFeedback': {'blockReason': 'OTHER'},
              },
            ]),
          ),
        ]);
        await expectLater(
          _client(server, apiKey: 'OTHER').streamChat(_request),
          emitsError(
            isA<LlmRefusalException>()
                .having((e) => e.message, 'message', isNot(contains('OTHER')))
                .having((e) => e.category, 'category', '[redacted]'),
          ),
        );
      });

      test('throws error chunks as LlmApiException', () async {
        final server = FakeServer([
          FakeResponse.text(
            sse([
              {
                'error': {
                  'code': 503,
                  'message': 'The model is overloaded.',
                  'status': 'UNAVAILABLE',
                },
              },
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsError(
            isA<LlmApiException>()
                .having((e) => e.message, 'message', 'The model is overloaded.')
                .having((e) => e.statusCode, 'statusCode', 503),
          ),
        );
      });

      test('extracts the message from HTTP error bodies', () async {
        final error = {
          'error': {
            'code': 400,
            'message': 'API key not valid. Please pass a valid API key.',
            'status': 'INVALID_ARGUMENT',
          },
        };
        for (final body in [
          error,
          [error],
        ]) {
          final server = FakeServer([FakeResponse.json(body, statusCode: 400)]);
          await expectLater(
            _client(server).streamChat(_request),
            emitsError(
              isA<LlmApiException>()
                  .having((e) => e.message, 'message', startsWith('API key'))
                  .having((e) => e.statusCode, 'statusCode', 400),
            ),
          );
        }
      });
    });

    group('listModels', () {
      test('lists generateContent models without the models/ prefix', () async {
        final server = FakeServer([
          FakeResponse.json({
            'models': [
              {
                'name': 'models/gemini-flash-latest',
                'displayName': 'Gemini Flash Latest',
                'inputTokenLimit': 1048576,
                'supportedGenerationMethods': [
                  'generateContent',
                  'countTokens',
                ],
              },
              {
                'name': 'models/text-embedding-004',
                'supportedGenerationMethods': ['embedContent'],
              },
              {'name': 'models/aqa'},
              {'name': 'custom-name'},
              {'name': ''},
              {'displayName': 'No name'},
            ],
          }),
        ]);
        final models = await _client(server).listModels();
        final request = server.lastRequest;
        expect(request.method, 'GET');
        expect(request.url, Uri.parse('$_base/models?pageSize=1000'));
        expect(request.headers['x-goog-api-key'], 'AIza-test');
        expect(models.map((m) => m.id), [
          'aqa',
          'custom-name',
          'gemini-flash-latest',
        ]);
        expect(models.last.displayName, 'Gemini Flash Latest');
        expect(models.last.contextWindow, 1048576);
        expect(models.first.displayName, isNull);
        expect(models.first.contextWindow, isNull);
      });

      test('rejects unexpected responses', () async {
        final server = FakeServer([FakeResponse.json(<String, Object?>{})]);
        await expectLater(
          _client(server).listModels(),
          throwsA(isA<LlmApiException>()),
        );
      });
    });
  });
}
