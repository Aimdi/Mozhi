import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

OllamaClient _client(
  FakeServer server, {
  String? apiKey,
  String baseUrl = 'http://localhost:11434',
  Duration? keepAlive,
  OllamaContextSizes? contextSizes,
}) => OllamaClient(
  LlmEndpoint(
    provider: LlmProvider.ollama,
    baseUrl: Uri.parse(baseUrl),
    apiKey: apiKey,
  ),
  httpClient: server.client,
  retryPolicy: LlmRetryPolicy.none,
  keepAlive: keepAlive,
  contextSizes: contextSizes ?? OllamaContextSizes(),
);

const _request = LlmRequest(
  model: 'qwen3:8b',
  messages: [
    LlmMessage.system('You translate.'),
    LlmMessage.user('Hallo'),
    LlmMessage.assistant('Hello'),
  ],
);

String _ndjson(List<Map<String, Object?>> lines) =>
    lines.map((line) => '${jsonEncode(line)}\n').join();

Map<String, Object?> _line(String content, {String? thinking, bool? done}) => {
  'model': 'qwen3:8b',
  'message': {'role': 'assistant', 'content': content, 'thinking': ?thinking},
  'done': done ?? false,
};

void main() {
  group(OllamaClient, () {
    group('streamChat request', () {
      test('posts the exact body and headers', () async {
        final server = FakeServer([
          FakeResponse.text(_ndjson([_line('', done: true)])),
        ]);
        await _client(server).streamChat(_request).drain<void>();

        final request = server.lastRequest;
        expect(request.method, 'POST');
        expect(request.url, Uri.parse('http://localhost:11434/api/chat'));
        expect(request.headers['content-type'], 'application/json');
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(request.json, {
          'model': 'qwen3:8b',
          'messages': [
            {'role': 'system', 'content': 'You translate.'},
            {'role': 'user', 'content': 'Hallo'},
            {'role': 'assistant', 'content': 'Hello'},
          ],
          'stream': true,
          'options': {'num_ctx': 8192},
        });
      });

      test('sends options, format, images and the key when set', () async {
        final server = FakeServer([
          FakeResponse.text(_ndjson([_line('', done: true)])),
        ]);
        await _client(server, apiKey: 'proxy-key')
            .streamChat(
              const LlmRequest(
                model: 'llava',
                messages: [
                  LlmMessage.user(
                    'What is this?',
                    images: [
                      LlmImage(bytes: [1, 2, 3]),
                    ],
                  ),
                ],
                temperature: 0.1,
                maxTokens: 256,
                jsonOutput: true,
                effort: 'low',
                contextWindow: 4096,
              ),
            )
            .drain<void>();
        expect(server.lastRequest.headers['authorization'], 'Bearer proxy-key');
        expect(server.lastRequest.json, {
          'model': 'llava',
          'messages': [
            {
              'role': 'user',
              'content': 'What is this?',
              'images': ['AQID'],
            },
          ],
          'stream': true,
          'options': {'temperature': 0.1, 'num_predict': 256, 'num_ctx': 4096},
          'format': 'json',
        });
      });

      test('sends the sampling options and stop strings when set', () async {
        final server = FakeServer([
          FakeResponse.text(_ndjson([_line('', done: true)])),
        ]);
        await _client(server)
            .streamChat(
              _request.copyWith(
                topP: 0.6,
                topK: 20,
                repeatPenalty: 1.05,
                stop: ['</s>'],
              ),
            )
            .drain<void>();
        expect((server.lastRequest.json! as Map)['options'], {
          'top_p': 0.6,
          'top_k': 20,
          'repeat_penalty': 1.05,
          'num_ctx': 8192,
          'stop': ['</s>'],
        });
      });
    });

    group('contextWindowFor', () {
      LlmRequest request(
        int characters, {
        int images = 0,
        int? maxTokens,
        int? contextWindow,
      }) => LlmRequest(
        model: 'qwen3:8b',
        messages: [
          const LlmMessage.system('ab'),
          LlmMessage.user(
            'x' * (characters - 2),
            images: [
              for (var i = 0; i < images; i++) const LlmImage(bytes: [1]),
            ],
          ),
        ],
        maxTokens: maxTokens,
        contextWindow: contextWindow,
      );

      test('defaults to 8192 tokens', () {
        expect(OllamaClient.defaultContextWindow, 8192);
        expect(OllamaClient.contextWindowFor(request(2)), 8192);
        // Estimate: 3584 + 3584 (reply) + 1024 = 8192.
        expect(OllamaClient.contextWindowFor(request(7168)), 8192);
      });

      test('doubles for long prompts up to 32768 tokens', () {
        expect(OllamaClient.contextWindowFor(request(7170)), 16384);
        expect(OllamaClient.contextWindowFor(request(15360)), 16384);
        expect(OllamaClient.contextWindowFor(request(15362)), 32768);
        expect(OllamaClient.maxAutoContextWindow, 32768);
        expect(OllamaClient.contextWindowFor(request(500000)), 32768);
      });

      test('counts maxTokens and images', () {
        // Estimate: 1 + 7167 (reply) + 1024 = 8192.
        expect(
          OllamaClient.contextWindowFor(request(2, maxTokens: 7167)),
          8192,
        );
        expect(
          OllamaClient.contextWindowFor(request(2, maxTokens: 7168)),
          16384,
        );
        expect(OllamaClient.contextWindowFor(request(2, images: 6)), 8192);
        expect(OllamaClient.contextWindowFor(request(2, images: 7)), 16384);
      });

      test('uses a positive LlmRequest.contextWindow as is', () {
        expect(
          OllamaClient.contextWindowFor(request(500000, contextWindow: 2048)),
          2048,
        );
        expect(
          OllamaClient.contextWindowFor(request(2, contextWindow: 131072)),
          131072,
        );
        expect(
          OllamaClient.contextWindowFor(request(2, contextWindow: 0)),
          8192,
        );
        expect(
          OllamaClient.contextWindowFor(request(2, contextWindow: -1)),
          8192,
        );
      });

      test('sends the estimate as options.num_ctx', () async {
        final server = FakeServer([
          FakeResponse.text(_ndjson([_line('', done: true)])),
        ]);
        await _client(server).streamChat(request(20000)).drain<void>();
        expect(
          server.lastRequest.json,
          containsPair('options', {'num_ctx': 32768}),
        );
      });
    });

    group('streamChat response', () {
      final body = _ndjson([
        _line('', thinking: 'Let me think'),
        _line('<think>inline reasoning</think>\n\n'),
        _line('Grüße, '),
        {'model': 'qwen3:8b', 'created_at': '2026-10-13T00:00:00Z'},
        _line('世界 👋'),
        _line('', done: true),
      ]);

      test('yields message content for any chunk boundaries', () async {
        for (final size in awkwardChunkSizes) {
          final server = FakeServer([
            FakeResponse.text(body.replaceAll('\n', '\r\n'), chunkSize: size),
          ]);
          expect(
            await _client(server).chat(_request),
            'Grüße, 世界 👋',
            reason: 'chunk size $size',
          );
        }
      });

      test('throws LlmTruncatedException at done_reason length', () async {
        final server = FakeServer([
          FakeResponse.text(
            _ndjson([
              _line('<think>plan</think>\n'),
              _line('Partial para 1'),
              {..._line('', done: true), 'done_reason': 'length'},
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsInOrder(<Object>[
            'Partial para 1',
            emitsError(
              isA<LlmTruncatedException>()
                  .having((e) => e.reason, 'reason', 'length')
                  .having(
                    (e) => e.partialText,
                    'partialText',
                    'Partial para 1',
                  ),
            ),
          ]),
        );
      });

      test('completes at done_reason stop', () async {
        final server = FakeServer([
          FakeResponse.text(
            _ndjson([
              _line('Bonjour'),
              {..._line('', done: true), 'done_reason': 'stop'},
            ]),
          ),
        ]);
        expect(await _client(server).chat(_request), 'Bonjour');
      });

      test('throws LlmInterruptedException without done: true', () async {
        final server = FakeServer([
          FakeResponse.text(_ndjson([_line('Bonjour, '), _line('comment')])),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsInOrder(<Object>[
            'Bonjour, ',
            'comment',
            emitsError(
              isA<LlmInterruptedException>().having(
                (e) => e.partialText,
                'partialText',
                'Bonjour, comment',
              ),
            ),
          ]),
        );
      });

      test('throws error lines as LlmApiException', () async {
        final server = FakeServer([
          FakeResponse.text(
            _ndjson([
              _line('Hi'),
              {'error': 'an error was encountered while running the model'},
            ]),
          ),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsInOrder(<Object>[
            'Hi',
            emitsError(
              isA<LlmApiException>()
                  .having(
                    (e) => e.message,
                    'message',
                    'an error was encountered while running the model',
                  )
                  .having((e) => e.statusCode, 'statusCode', isNull),
            ),
          ]),
        );
      });

      test('reports malformed lines', () async {
        final server = FakeServer([FakeResponse.text('{"message":\n')]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsError(isA<LlmApiException>()),
        );
      });

      test('extracts the message from HTTP error bodies', () async {
        final server = FakeServer([
          FakeResponse.json({
            'error': "model 'qwen3:8b' not found, try pulling it first",
          }, statusCode: 404),
        ]);
        await expectLater(
          _client(server).streamChat(_request),
          emitsError(
            isA<LlmApiException>()
                .having((e) => e.message, 'message', contains('not found'))
                .having((e) => e.isNotFound, 'isNotFound', isTrue),
          ),
        );
      });
    });

    group('sticky context size', () {
      LlmRequest sized(int characters, {String model = 'qwen3:8b'}) =>
          LlmRequest(
            model: model,
            messages: [LlmMessage.user('x' * characters)],
          );

      Future<List<Object?>> sentSizes(
        OllamaClient client,
        FakeServer server,
        List<LlmRequest> requests,
      ) async {
        for (final request in requests) {
          server.enqueue(FakeResponse.text(_ndjson([_line('', done: true)])));
          await client.streamChat(request).drain<void>();
        }
        return [
          for (final request in server.requests)
            switch (request.json) {
              {'options': {'num_ctx': final Object size}} => size,
              _ => null,
            },
        ];
      }

      test('never shrinks for the same server and model', () async {
        final server = FakeServer();
        final sizes = OllamaContextSizes();
        final client = _client(server, contextSizes: sizes);
        expect(
          await sentSizes(client, server, [
            sized(10),
            sized(20000),
            sized(10),
            sized(9000),
          ]),
          [8192, 32768, 32768, 32768],
        );
        expect(sizes.sizeOf(client.endpoint.baseUrl, 'qwen3:8b'), 32768);
      });

      test('is kept per model and server', () async {
        final server = FakeServer();
        final sizes = OllamaContextSizes();
        final client = _client(server, contextSizes: sizes);
        expect(
          await sentSizes(client, server, [
            sized(20000),
            sized(10, model: 'gemma3:4b'),
          ]),
          [32768, 8192],
        );
        final other = FakeServer();
        expect(
          await sentSizes(
            _client(
              other,
              baseUrl: 'http://192.168.1.5:11434',
              contextSizes: sizes,
            ),
            other,
            [sized(10)],
          ),
          [8192],
        );
      });

      test('is shared by clients of the same server', () async {
        final sizes = OllamaContextSizes();
        final first = FakeServer();
        await sentSizes(_client(first, contextSizes: sizes), first, [
          sized(9000),
        ]);
        final second = FakeServer();
        expect(
          await sentSizes(
            _client(
              second,
              baseUrl: 'http://localhost:11434/',
              contextSizes: sizes,
            ),
            second,
            [sized(10)],
          ),
          [16384],
        );
      });

      test('a positive LlmRequest.contextWindow is sent as is and not '
          'remembered', () async {
        final server = FakeServer();
        final sizes = OllamaContextSizes();
        final client = _client(server, contextSizes: sizes);
        expect(
          await sentSizes(client, server, [
            sized(10),
            sized(10).copyWith(contextWindow: 65536),
            sized(10).copyWith(contextWindow: 2048),
            sized(10),
          ]),
          [8192, 65536, 2048, 8192],
        );
      });

      test('clients share OllamaContextSizes.shared by default', () {
        final client = OllamaClient(
          LlmEndpoint(
            provider: LlmProvider.ollama,
            baseUrl: Uri.parse('http://localhost:11434'),
          ),
          httpClient: FakeServer().client,
        );
        expect(client.contextSizes, same(OllamaContextSizes.shared));
        expect(client.keepAlive, isNull);
      });
    });

    group('OllamaContextSizes', () {
      test('raises, remembers and forgets sizes', () {
        final sizes = OllamaContextSizes();
        final base = Uri.parse('http://localhost:11434/');
        expect(sizes.sizeOf(base, 'm'), isNull);
        expect(sizes.raise(base, 'm', 8192), 8192);
        expect(sizes.raise(base, ' m ', 4096), 8192);
        expect(
          sizes.raise(Uri.parse('http://localhost:11434'), 'm', 16384),
          16384,
        );
        expect(sizes.sizeOf(base, 'm'), 16384);
        sizes.clear();
        expect(sizes.sizeOf(base, 'm'), isNull);
      });
    });

    group('keepAlive', () {
      Future<Object?> sentKeepAlive(Duration? keepAlive) async {
        final server = FakeServer([
          FakeResponse.text(_ndjson([_line('', done: true)])),
        ]);
        await _client(
          server,
          keepAlive: keepAlive,
        ).streamChat(_request).drain<void>();
        final json = server.lastRequest.json! as Map<String, Object?>;
        return json.containsKey('keep_alive') ? json['keep_alive'] : 'absent';
      }

      test('is sent in whole seconds, -1 for forever', () async {
        expect(await sentKeepAlive(null), 'absent');
        expect(await sentKeepAlive(const Duration(minutes: 30)), 1800);
        expect(await sentKeepAlive(const Duration(milliseconds: 1500)), 1);
        expect(await sentKeepAlive(Duration.zero), 0);
        expect(await sentKeepAlive(const Duration(seconds: -1)), -1);
      });
    });

    group('warmUp', () {
      test('loads the model with the size chat requests will use', () async {
        final server = FakeServer([
          FakeResponse.text(_ndjson([_line('', done: true)])),
          FakeResponse.json({
            'model': 'qwen3:8b',
            'response': '',
            'done': true,
            'done_reason': 'load',
          }),
          FakeResponse.json({'model': 'gemma3:4b', 'done': true}),
        ]);
        final client = _client(
          server,
          apiKey: 'k',
          keepAlive: const Duration(minutes: 10),
        );
        await client
            .streamChat(
              LlmRequest(
                model: 'qwen3:8b',
                messages: [LlmMessage.user('x' * 9000)],
              ),
            )
            .drain<void>();

        expect(await client.warmUp(' qwen3:8b '), isTrue);
        final warm = server.requests[1];
        expect(warm.method, 'POST');
        expect(warm.url, Uri.parse('http://localhost:11434/api/generate'));
        expect(warm.headers['authorization'], 'Bearer k');
        expect(warm.headers['content-type'], 'application/json');
        expect(warm.json, {
          'model': 'qwen3:8b',
          'stream': false,
          'options': {'num_ctx': 16384},
          'keep_alive': 600,
        });
        await expectLater(warm.abortTrigger, completes);

        // A model not used yet gets the default size, which is remembered.
        expect(await client.warmUp('gemma3:4b'), isTrue);
        expect(
          server.lastRequest.json,
          containsPair('options', {'num_ctx': 8192}),
        );
        expect(
          client.contextSizes.sizeOf(client.endpoint.baseUrl, 'gemma3:4b'),
          8192,
        );
      });

      test('answers false instead of throwing', () async {
        final server = FakeServer([
          FakeResponse.json({'error': 'model "x" not found'}, statusCode: 404),
          FakeResponse.json({'error': 'still loading'}),
          FakeResponse.text('not json'),
        ]);
        final client = _client(server);
        expect(await client.warmUp('x'), isFalse);
        expect(await client.warmUp('x'), isFalse);
        expect(await client.warmUp('x'), isFalse);
        // Nothing is sent without a model.
        expect(await client.warmUp('  '), isFalse);
        expect(server.requests, hasLength(3));
        // Transport errors too (the fake server has no more answers).
        expect(await client.warmUp('x'), isFalse);
      });

      test('omits keep_alive when none is set', () async {
        final server = FakeServer([
          FakeResponse.json({'done': true}),
        ]);
        expect(await _client(server).warmUp('m'), isTrue);
        expect(
          (server.lastRequest.json! as Map<String, Object?>).containsKey(
            'keep_alive',
          ),
          isFalse,
        );
      });
    });

    group('listModels', () {
      test('gets {base}/api/tags', () async {
        final server = FakeServer([
          FakeResponse.json({
            'models': [
              {'name': 'qwen3:8b', 'model': 'qwen3:8b', 'size': 5},
              {'name': 'gemma3:4b'},
              {'name': ''},
              'junk',
            ],
          }),
        ]);
        final models = await _client(server, apiKey: 'k').listModels();
        expect(server.lastRequest.method, 'GET');
        expect(
          server.lastRequest.url,
          Uri.parse('http://localhost:11434/api/tags'),
        );
        expect(server.lastRequest.headers['authorization'], 'Bearer k');
        expect(models.map((m) => m.id), ['gemma3:4b', 'qwen3:8b']);
      });

      test('rejects unexpected responses', () async {
        final server = FakeServer([
          FakeResponse.json({'models': 'none'}),
        ]);
        await expectLater(
          _client(server).listModels(),
          throwsA(isA<LlmApiException>()),
        );
      });
    });
  });
}
