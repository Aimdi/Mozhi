import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:test/test.dart';

import '../../helpers/fake_server.dart';

OllamaClient _client(FakeServer server, {String? apiKey}) => OllamaClient(
  LlmEndpoint(
    provider: LlmProvider.ollama,
    baseUrl: Uri.parse('http://localhost:11434'),
    apiKey: apiKey,
  ),
  httpClient: server.client,
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
        final server = FakeServer([FakeResponse.text(_ndjson([_line('', done: true)]))]);
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
        });
      });

      test('sends options, format, images and the key when set', () async {
        final server = FakeServer([FakeResponse.text(_ndjson([_line('', done: true)]))]);
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
          'options': {'temperature': 0.1, 'num_predict': 256},
          'format': 'json',
        });
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
                  .having((e) => e.partialText, 'partialText', 'Partial para 1'),
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
