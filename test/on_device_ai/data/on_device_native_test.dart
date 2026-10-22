@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:path/path.dart' as p;
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

/// The Linux build of the engine and its scripted test models
/// (packages/llama_engine: `tool/build_native_linux.sh`,
/// `tool/make_test_model.py --all build/test_models`): after a ChatML or
/// Qwen3 prompt they answer the alphabet and 中 (or `{}` with the JSON
/// grammar), after a Gemma 4 or Hunyuan prompt digits without end. The
/// "Hy-MT2" here is the Qwen3-template model with Hy-MT2's prompt profile,
/// so that its translation ends.
final String _package = p.absolute('packages', 'llama_engine');
final String _library = p.join(
  _package,
  'build',
  'native',
  'linux',
  'libmozhi_llama.so',
);

String _model(String template) =>
    p.join(_package, 'build', 'test_models', 'llama-test-$template.gguf');

Object _skip() {
  if (!File(_library).existsSync()) return 'libmozhi_llama.so not built';
  for (final template in ['hunyuan-dense', 'qwen3', 'gemma4']) {
    if (!File(_model(template)).existsSync()) return 'test models missing';
  }
  return false;
}

const _alphabet = 'abcdefghijklmnopqrstuvwxyz中';

void main() {
  group('on-device AI with the native engine', skip: _skip(), () {
    late OnDeviceAi ai;
    late TranslationRepository repository;

    setUp(() {
      final catalog = LlamaModelCatalog(
        models: [
          catalogModel(
            'hy-test',
            role: LlamaModelRole.translation,
            family: 'qwen3',
            contextSize: 2048,
          ),
          catalogModel('qwen-test', family: 'qwen3', contextSize: 2048),
          catalogModel('gemma-test', family: 'gemma4', contextSize: 2048),
        ],
      );
      ai = OnDeviceAi(
        models: FakeOnDeviceModels(
          catalog: catalog,
          paths: {
            'hy-test': _model('qwen3'),
            'qwen-test': _model('qwen3'),
            'gemma-test': _model('gemma4'),
          },
          translationModel: 'hy-test',
          assistantModel: 'qwen-test',
        ),
        engine: createLlamaEngine(libraryPath: _library),
      );
      repository =
          TranslationRepository(
              llmClientFactory: onDeviceClientFactory(
                ai,
                (_) => throw StateError('No network in this test'),
              ),
              snapshotInterval: Duration.zero,
            )
            ..updateConfiguration(instances: const [], providers: ai.providers)
            ..updatePrivacy(mode: PrivacyMode.offlineOnly);
    });

    tearDown(() async {
      repository.dispose();
      await ai.dispose();
    });

    test('translates in Offline only, on the device', () async {
      final statuses = <OnDeviceAiStatus>[];
      ai.status.listen(statuses.add);
      final engine = (await repository.getEngines()).first;
      expect(engine.id, 'ai:device-hy-test');
      final result = await repository
          .translate(
            engine,
            const TranslationRequest(
              text: 'Hello',
              source: Language(code: 'en', name: 'English'),
              target: Language(code: 'de', name: 'German'),
            ),
          )
          .last;
      expect(result.text, _alphabet);
      expect(result.isComplete, isTrue);
      expect(result.destination, const OnDeviceDestination());
      await pumpEventQueue();
      expect(statuses, const [
        OnDeviceAiLoading('hy-test'),
        OnDeviceAiGenerating('hy-test'),
        OnDeviceAiIdle(),
      ]);
    });

    test('the assistant answers, cut off at its limit', () async {
      final client = ai.client(ai.providers.last.toEndpoint());
      const hello = [LlmMessage.system('Be brief.'), LlmMessage.user('Hi')];
      expect(
        await client.chat(
          const LlmRequest(model: 'qwen-test', messages: hello),
        ),
        _alphabet,
      );
      await expectLater(
        client.chat(
          const LlmRequest(model: 'qwen-test', messages: hello, maxTokens: 5),
        ),
        throwsA(
          isA<LlmTruncatedException>().having(
            (e) => e.partialText,
            'partialText',
            'abcde',
          ),
        ),
      );
    });

    test('JSON replies follow the grammar; models switch', () async {
      final client = ai.client(ai.providers.last.toEndpoint());
      final answer = await client.chat(
        const LlmRequest(
          model: 'qwen-test',
          messages: [LlmMessage.user('JSON please')],
          jsonOutput: true,
        ),
      );
      expect(jsonDecode(answer), <String, Object?>{});
      expect(ai.runtime.loadedModelId, 'qwen-test');
      expect(await client.warmUp('gemma-test'), isTrue);
      expect(ai.runtime.loadedModelId, 'gemma-test');
      // Gemma 4's template: digits until the limit.
      await expectLater(
        client.chat(
          const LlmRequest(
            model: 'gemma-test',
            messages: [LlmMessage.user('Count')],
            maxTokens: 12,
          ),
        ),
        throwsA(
          isA<LlmTruncatedException>().having(
            (e) => e.partialText,
            'partialText',
            '012345678901',
          ),
        ),
      );
    });

    test('a prompt longer than the context fails clearly', () async {
      final client = ai.client(ai.providers.last.toEndpoint());
      await expectLater(
        client.chat(
          LlmRequest(
            model: 'qwen-test',
            messages: [LlmMessage.user('word ' * 4000)],
          ),
        ),
        throwsA(
          isA<LlmApiException>().having(
            (e) => e.message,
            'message',
            contains('too long for the on-device model'),
          ),
        ),
      );
    });
  });
}
