import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart';
import 'package:llm_api/src/providers/http_llm_client.dart';
import 'package:test/test.dart';

import '../helpers/fake_server.dart';

class _TrackingClient extends MockClient {
  new() : super((_) async => http.Response('', 200));

  bool closed = false;

  @override
  void close() => closed = true;
}

void main() {
  group(LlmClient, () {
    LlmEndpoint endpointFor(LlmProvider provider) =>
        LlmEndpoint(provider: provider, baseUrl: Uri.parse('http://x'));

    test('dispatches on the endpoint provider', () {
      final types = {
        LlmProvider.openAiCompatible: isA<OpenAiCompatibleClient>(),
        LlmProvider.anthropic: isA<AnthropicClient>(),
        LlmProvider.gemini: isA<GeminiClient>(),
        LlmProvider.ollama: isA<OllamaClient>(),
      };
      for (final MapEntry(key: provider, value: matcher) in types.entries) {
        final endpoint = endpointFor(provider);
        final client = LlmClient(
          endpoint,
          httpClient: FakeServer().client,
          timeout: const Duration(seconds: 5),
        );
        expect(client, matcher);
        expect(client.endpoint, same(endpoint));
        expect(client.timeout, const Duration(seconds: 5));
      }
    });

    test('passes the retry policy and keep-alive on', () {
      const policy = LlmRetryPolicy(maxRetries: 3);
      for (final provider in LlmProvider.values) {
        final client = LlmClient(
          endpointFor(provider),
          httpClient: FakeServer().client,
          retryPolicy: policy,
          keepAlive: const Duration(minutes: 5),
        );
        expect(
          (client as HttpLlmClient).retryPolicy,
          same(policy),
          reason: provider.name,
        );
      }
      final ollama = LlmClient(
        endpointFor(LlmProvider.ollama),
        httpClient: FakeServer().client,
        keepAlive: const Duration(minutes: 5),
      );
      expect((ollama as OllamaClient).keepAlive, const Duration(minutes: 5));
      expect(ollama.retryPolicy, same(LlmRetryPolicy.standard));
      expect(ollama.contextSizes, same(OllamaContextSizes.shared));
    });

    test('warmUp does nothing for cloud providers', () async {
      for (final provider in [
        LlmProvider.openAiCompatible,
        LlmProvider.anthropic,
        LlmProvider.gemini,
      ]) {
        final server = FakeServer();
        final client = LlmClient(
          endpointFor(provider),
          httpClient: server.client,
        );
        expect(await client.warmUp('m'), isFalse, reason: provider.name);
        expect(server.requests, isEmpty, reason: provider.name);
      }
    });

    test('defaults the timeout', () {
      final client = LlmClient(endpointFor(LlmProvider.ollama));
      expect(client.timeout, LlmClient.defaultTimeout);
      client.close();
    });

    test('close does not close an injected http client', () {
      final httpClient = _TrackingClient();
      LlmClient(
        endpointFor(LlmProvider.gemini),
        httpClient: httpClient,
      ).close();
      expect(httpClient.closed, isFalse);
    });

    test('LlmRequest.contextWindow only changes Ollama requests', () async {
      const request = LlmRequest(model: 'm', messages: [LlmMessage.user('Hi')]);
      for (final provider in LlmProvider.values) {
        final server = FakeServer([
          FakeResponse.text(''),
          FakeResponse.text(''),
        ]);
        final client = LlmClient(
          endpointFor(provider),
          httpClient: server.client,
          // The empty responses would otherwise be retried.
          retryPolicy: LlmRetryPolicy.none,
        );
        for (final sent in [request, request.copyWith(contextWindow: 2048)]) {
          try {
            await client.streamChat(sent).drain<void>();
          } on LlmInterruptedException {
            // The scripted responses are empty.
          }
        }
        final [plain, sized] = server.requests;
        if (provider == LlmProvider.ollama) {
          expect(plain.json, containsPair('options', {'num_ctx': 8192}));
          expect(sized.json, containsPair('options', {'num_ctx': 2048}));
        } else {
          expect(sized.body, plain.body, reason: provider.name);
        }
      }
    });

    test('chat concatenates the streamed deltas', () async {
      final server = FakeServer([
        FakeResponse.text(
          sse([
            {
              'choices': [
                {
                  'delta': {'content': 'Hello'},
                },
              ],
            },
            {
              'choices': [
                {
                  'delta': {'content': ', world'},
                },
              ],
            },
            '[DONE]',
          ]),
        ),
      ]);
      final client = LlmClient(
        endpointFor(LlmProvider.openAiCompatible),
        httpClient: server.client,
      );
      expect(
        await client.chat(
          const LlmRequest(model: 'm', messages: [LlmMessage.user('Hi')]),
        ),
        'Hello, world',
      );
    });
  });
}
