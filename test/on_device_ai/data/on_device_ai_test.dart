import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/data/on_device_llm_client.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:translation_repository/translation_repository.dart';

import 'helpers.dart';

class _MockLlmClient extends Mock implements LlmClient;

void main() {
  late FakeOnDeviceModels models;
  late FakeLlamaEngine engine;
  late NativeMemoryBudget budget;
  late OnDeviceAi ai;

  setUp(() {
    models = FakeOnDeviceModels(
      translationModel: 'hy-mt2',
      assistantModel: 'gemma',
    );
    engine = FakeLlamaEngine();
    budget = NativeMemoryBudget();
    ai = OnDeviceAi(models: models, engine: engine, memoryBudget: budget);
  });

  tearDown(() => ai.dispose());

  group('providers', () {
    test('are the selected models, translation first', () {
      expect(ai.providers, [
        const AiProviderConfig(
          id: 'device-hy-mt2',
          name: 'Model hy-mt2 (on this device)',
          provider: LlmProvider.onDevice,
          baseUrl: '',
          model: 'hy-mt2',
          promptProfile: PromptProfile.hunyuanMt,
        ),
        const AiProviderConfig(
          id: 'device-gemma',
          name: 'Model gemma (on this device)',
          provider: LlmProvider.onDevice,
          baseUrl: '',
          model: 'gemma',
          promptProfile: PromptProfile.general,
        ),
      ]);
      for (final provider in ai.providers) {
        expect(provider.isOnDevice, isTrue);
        expect(provider.supportsVision, isFalse);
        expect(provider.toEndpoint().baseUrl.host, provider.model);
      }
    });

    test('are none without a selection', () async {
      final empty = OnDeviceAi(
        models: FakeOnDeviceModels(),
        engine: FakeLlamaEngine(),
      );
      addTearDown(empty.dispose);
      expect(empty.providers, isEmpty);
    });

    test('an unknown profile resolves from the model id', () {
      expect(
        OnDeviceAi.providerFor(catalogModel('x', promptProfile: 'unknown'))
            .promptProfile,
        PromptProfile.auto,
      );
    });

    test('follow the selection', () async {
      final changes = <List<AiProviderConfig>>[];
      ai.providersChanges.listen(changes.add);
      models
        ..assistantModel = 'qwen'
        ..changed();
      await pumpEventQueue();
      expect(changes.single.map((p) => p.id), ['device-hy-mt2', 'device-qwen']);
      expect(ai.providers, changes.single);
      // Nothing changed: nothing emitted.
      models.changed();
      await pumpEventQueue();
      expect(changes, hasLength(1));
    });

    test('a model that is no longer selected leaves memory', () async {
      await ai.client(ai.providers.last.toEndpoint()).warmUp('gemma');
      expect(ai.runtime.loadedModelId, 'gemma');
      models
        ..assistantModel = null
        ..changed();
      await pumpEventQueue();
      expect(engine.unloads, 1);
      expect(ai.providers.map((p) => p.id), ['device-hy-mt2']);
    });
  });

  group('client', () {
    test('is the in-process client of on-device endpoints', () {
      final client = ai.client(ai.providers.first.toEndpoint());
      expect(client, isA<OnDeviceLlmClient>());
      expect(client.endpoint.provider, LlmProvider.onDevice);
    });

    test('rejects other endpoints', () {
      expect(
        () => ai.client(
          LlmEndpoint(
            provider: LlmProvider.ollama,
            baseUrl: Uri.parse('http://localhost:11434'),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('runs the selected model', () async {
      final statuses = <OnDeviceAiStatus>[];
      ai.status.listen(statuses.add);
      final provider = ai.providers.last;
      final text = await ai
          .client(provider.toEndpoint())
          .chat(
            LlmRequest(
              model: provider.model,
              messages: const [LlmMessage.user('Hi')],
            ),
          );
      expect(text, 'Hi');
      await pumpEventQueue();
      expect(statuses, const [
        OnDeviceAiLoading('gemma'),
        OnDeviceAiGenerating('gemma'),
        OnDeviceAiIdle(),
      ]);
      expect(ai.currentStatus, const OnDeviceAiIdle());
    });
  });

  group('unload', () {
    test('on memory pressure and in the background', () async {
      final client = ai.client(ai.providers.last.toEndpoint());
      await client.warmUp('gemma');
      budget.didHaveMemoryPressure();
      await pumpEventQueue();
      expect(engine.unloads, 1);
      await client.warmUp('gemma');
      budget.didChangeAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(engine.unloads, 2);
    });

    test('does nothing after dispose', () async {
      await ai.dispose();
      await ai.unload();
      expect(engine.unloads, 0);
    });
  });

  test('dispose stops the engine and closes the models once', () async {
    await ai.dispose();
    await ai.dispose();
    expect(engine.disposed, isTrue);
    expect(models.disposed, isTrue);
  });

  group('withOnDeviceProviders', () {
    const claude = AiProviderConfig(
      id: 'p1',
      name: 'Claude',
      provider: LlmProvider.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      model: 'claude',
    );

    test('adds the on-device providers after the configured ones', () {
      expect(withOnDeviceProviders(const [claude], ai), [
        claude,
        ...ai.providers,
      ]);
      const configured = [claude];
      expect(withOnDeviceProviders(configured, null), same(configured));
    });

    test('drops a stored provider with an on-device id', () {
      final crafted = claude.copyWith(baseUrl: 'https://evil.example');
      final stored = AiProviderConfig.fromJson({
        ...crafted.toJson(),
        'id': 'device-hy-mt2',
      });
      expect(withOnDeviceProviders([stored, claude], ai), [
        claude,
        ...ai.providers,
      ]);
    });
  });

  test('onDeviceClientFactory routes on-device endpoints', () {
    final network = _MockLlmClient();
    final factory = onDeviceClientFactory(ai, (_) => network);
    expect(factory(ai.providers.first.toEndpoint()), isA<OnDeviceLlmClient>());
    final cloud = LlmEndpoint(
      provider: LlmProvider.openAiCompatible,
      baseUrl: Uri.parse('https://api.example.com/v1'),
    );
    expect(factory(cloud), same(network));
    // Without on-device AI, every endpoint goes to the network factory.
    expect(
      onDeviceClientFactory(null, (_) => network)(
        ai.providers.first.toEndpoint(),
      ),
      same(network),
    );
  });

  group('OnDeviceAiStatus', () {
    test('says what runs', () {
      const idle = OnDeviceAiIdle();
      const loading = OnDeviceAiLoading('a');
      const generating = OnDeviceAiGenerating('a');
      final error = OnDeviceAiError('a', StateError('x'));
      expect(idle.modelId, isNull);
      expect(loading.modelId, 'a');
      expect(loading.isLoading, isTrue);
      expect(loading.isGenerating, isFalse);
      expect(generating.isGenerating, isTrue);
      expect(error.modelId, 'a');
      expect(idle.isLoading || idle.isGenerating, isFalse);
    });

    test('compares by kind, model and error', () {
      final boom = StateError('x');
      expect(const OnDeviceAiIdle(), const OnDeviceAiIdle());
      expect(const OnDeviceAiLoading('a'), const OnDeviceAiLoading('a'));
      expect(const OnDeviceAiLoading('a'), isNot(const OnDeviceAiLoading('b')));
      expect(
        const OnDeviceAiLoading('a'),
        isNot(const OnDeviceAiGenerating('a')),
      );
      expect(OnDeviceAiError('a', boom), OnDeviceAiError('a', boom));
      expect(OnDeviceAiError('a', boom), isNot(OnDeviceAiError('b', boom)));
      expect({
        const OnDeviceAiIdle().hashCode,
        const OnDeviceAiLoading('a').hashCode,
        const OnDeviceAiGenerating('a').hashCode,
        OnDeviceAiError('a', boom).hashCode,
      }, hasLength(4));
      expect(
        [
          const OnDeviceAiIdle(),
          const OnDeviceAiLoading('a'),
          const OnDeviceAiGenerating('a'),
          OnDeviceAiError('a', boom),
        ].map((s) => '$s'),
        [
          'OnDeviceAiIdle()',
          'OnDeviceAiLoading(a)',
          'OnDeviceAiGenerating(a)',
          'OnDeviceAiError(a)',
        ],
      );
    });
  });
}
