import 'dart:async';
import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

/// Models that run inside the app (`LlmProvider.onDevice`): nothing leaves
/// the device, so the privacy rules never stop them.
void main() {
  setUpAll(registerTestFallbacks);

  const hyMt = AiProviderConfig(
    id: 'device-hy-mt2-1.8b-q4',
    name: 'Hy-MT2 1.8B (on this device)',
    provider: LlmProvider.onDevice,
    baseUrl: '',
    model: 'hy-mt2-1.8b-q4',
    promptProfile: PromptProfile.hunyuanMt,
  );
  const gemma = AiProviderConfig(
    id: 'device-gemma-4-e2b-q4',
    name: 'Gemma 4 E2B (on this device)',
    provider: LlmProvider.onDevice,
    baseUrl: '',
    model: 'gemma-4-e2b-q4',
    promptProfile: PromptProfile.general,
  );
  const englishToGerman = TranslationRequest(
    text: 'Hello world',
    source: english,
    target: german,
  );

  late Map<String, MockLlmClient> llm;
  late List<LlmEndpoint> endpoints;
  late MockMozhiApiClient mozhi;
  late FakeOfflineTranslator offline;
  late TranslationRepository repository;

  TranslationRepository newRepository({
    int onDeviceAiChunkThreshold =
        TranslationRepository.defaultOnDeviceAiChunkThreshold,
  }) => TranslationRepository(
    mozhiClientFactory: (_) => mozhi,
    llmClientFactory: (endpoint) {
      endpoints.add(endpoint);
      return llm[endpoint.baseUrl.host]!;
    },
    offline: offline,
    snapshotInterval: Duration.zero,
    onDeviceAiChunkThreshold: onDeviceAiChunkThreshold,
  )..updatePrivacy(mode: PrivacyMode.offlineOnly);

  void configure([List<AiProviderConfig> providers = const [hyMt, gemma]]) =>
      repository.updateConfiguration(
        instances: const [instanceA],
        providers: providers,
      );

  MockLlmClient clientOf(AiProviderConfig config) => llm[config.model]!;

  void stubStream(AiProviderConfig config, List<String> deltas) =>
      when(() => clientOf(config).streamChat(any()))
          .thenAnswer((_) => Stream.fromIterable(deltas));

  LlmRequest capturedStream(AiProviderConfig config) =>
      verify(() => clientOf(config).streamChat(captureAny())).captured.single
          as LlmRequest;

  Future<TranslationEngine> engineOf(AiProviderConfig config) async =>
      (await repository.getEngines()).singleWhere(
        (engine) => engine.providerId == config.id,
      );

  setUp(() {
    llm = {
      for (final config in [hyMt, gemma]) config.model: MockLlmClient(),
    };
    endpoints = [];
    mozhi = MockMozhiApiClient();
    offline = FakeOfflineTranslator(identified: 'en');
    repository = newRepository();
    configure();
  });

  group('AiProviderConfig', () {
    test('is on device and local, with a device endpoint', () {
      expect(hyMt.isOnDevice, isTrue);
      expect(hyMt.isLocal, isTrue);
      final endpoint = hyMt.toEndpoint();
      expect(endpoint.provider, LlmProvider.onDevice);
      expect(endpoint.baseUrl, Uri.parse('device://hy-mt2-1.8b-q4'));
      expect(endpoint.baseUrl.scheme, AiProviderConfig.onDeviceScheme);
      expect(endpoint.apiKey, isNull);
      expect(endpoint.headers, isEmpty);
    });

    test('a machine translation service is never on device', () {
      final deepl = deeplConfig.copyWith(provider: LlmProvider.onDevice);
      expect(deepl.isOnDevice, isFalse);
      expect(deepl.isLocal, isFalse);
    });

    test('a stored provider never becomes an on-device one', () {
      final json = gemma.toJson();
      expect(json['provider'], 'onDevice');
      final read = AiProviderConfig.fromJson(json);
      expect(read.provider, LlmProvider.openAiCompatible);
      expect(read.isOnDevice, isFalse);
      expect(
        AiProviderConfig.fromJson({...json, 'provider': 'on-device'}).provider,
        LlmProvider.openAiCompatible,
      );
    });
  });

  group('engines', () {
    test('are AI engines that say they stay on the device', () async {
      final engine = await engineOf(hyMt);
      expect(engine.id, 'ai:device-hy-mt2-1.8b-q4');
      expect(engine.isAi, isTrue);
      expect(engine.onDevice, isTrue);
      expect(engine.isOnDevice, isTrue);
      expect(engine.isLocal, isTrue);
      expect(engine.usesMtProfile, isTrue);
      expect(engine.supportsGlossary, isTrue);
      expect((await engineOf(gemma)).supportsExtras, isTrue);
    });

    test('other engines are not on device, except the offline one', () {
      expect(aiEngine(ollamaConfig).isOnDevice, isFalse);
      expect(googleEngine.isOnDevice, isFalse);
      expect(mtEngine(libreConfig).isOnDevice, isFalse);
      expect(TranslationEngine.offline().isOnDevice, isTrue);
      // The flag only counts for AI engines.
      expect(
        const TranslationEngine(
          id: 'mt:x',
          kind: EngineKind.mt,
          name: 'X',
          onDevice: true,
        ).isOnDevice,
        isFalse,
      );
    });
  });

  group('privacy', () {
    test('the destination is the device', () {
      for (final config in [hyMt, gemma]) {
        expect(
          repository.destinationOf('ai:${config.id}'),
          const OnDeviceDestination(),
        );
      }
    });

    test('no consent is needed in any privacy mode', () async {
      final engine = await engineOf(gemma);
      for (final mode in PrivacyMode.values) {
        repository.updatePrivacy(mode: mode);
        expect(
          repository.needsConsent(engine, source: english, target: german),
          isFalse,
          reason: mode.name,
        );
      }
    });

    test('translates in Offline only without approved pairs', () async {
      stubStream(gemma, ['Hallo ', 'Welt']);
      final results = await repository
          .translate(await engineOf(gemma), englishToGerman)
          .toList();
      expect(results.last.text, 'Hallo Welt');
      expect(results.last.isComplete, isTrue);
      expect(results.last.destination, const OnDeviceDestination());
      expect(endpoints.single.provider, LlmProvider.onDevice);
      expect(endpoints.single.baseUrl.host, 'gemma-4-e2b-q4');
      verifyZeroInteractions(mozhi);
    });

    test('personal data is not masked: it stays on the device', () async {
      stubStream(gemma, ['Schreib an a@b.org']);
      final result = await repository
          .translate(
            await engineOf(gemma),
            englishToGerman.copyWith(text: 'Write to a@b.org'),
          )
          .last;
      expect(result.text, 'Schreib an a@b.org');
      expect(result.maskedPersonalData, 0);
      expect(capturedStream(gemma).messages.last.content, contains('a@b.org'));
    });

    test(
      'an auto source is identified on the device, never by Mozhi',
      () async {
        stubStream(hyMt, ['Hallo Welt']);
        final engine = await engineOf(hyMt);
        final auto = englishToGerman.copyWith(source: Language.auto);
        final result = await repository.translate(engine, auto).last;
        expect(result.detectedSource, 'en');
        expect(offline.identifyCalls, ['Hello world']);

        offline.identified = null;
        // Even where Mozhi would be allowed, it is not asked.
        repository.updatePrivacy(mode: PrivacyMode.online);
        await expectLater(
          repository.translate(engine, auto.copyWith(text: 'Hallo du')),
          emitsError(isA<SourceLanguageRequiredException>()),
        );
        verifyZeroInteractions(mozhi);
      },
    );
  });

  group('Hy-MT2 on the device', () {
    test('gets the MT prompt and the model card sampling', () async {
      stubStream(hyMt, ['Hallo Welt']);
      final result = await repository
          .translate(await engineOf(hyMt), englishToGerman)
          .last;
      expect(result.text, 'Hallo Welt');
      final request = capturedStream(hyMt);
      expect(
        request.messages,
        MtPrompts.translate(PromptProfile.hunyuanMt, englishToGerman),
      );
      expect(request.model, 'hy-mt2-1.8b-q4');
      expect(request.temperature, 0.7);
      expect(request.topP, 0.6);
      expect(request.topK, 20);
      expect(request.repeatPenalty, 1.05);
    });

    test('gets the glossary terms of the text', () async {
      stubStream(hyMt, ['Hallo Erde']);
      await repository
          .translate(
            await engineOf(hyMt),
            englishToGerman.copyWith(
              options: const TranslationOptions(glossary: {'world': 'Erde'}),
            ),
          )
          .drain<void>();
      expect(
        capturedStream(hyMt).messages.single.content,
        startsWith(
          'Reference the following translations:\n'
          'world translates to Erde\n',
        ),
      );
    });

    test('refuses the extras (a translation-only model)', () async {
      final engine = await engineOf(hyMt);
      expect(
        () => repository.getAlternatives(engine, englishToGerman, 'Hallo'),
        throwsArgumentError,
      );
      await expectLater(
        repository.explain(engine, englishToGerman, 'Hallo'),
        emitsError(isArgumentError),
      );
    });
  });

  group('the assistant model on the device', () {
    test('runs the extras in Offline only', () async {
      when(() => clientOf(gemma).chat(any())).thenAnswer(
        (_) async => jsonEncode({
          'description': 'Neutral greeting.',
          'alternatives': [
            {'text': 'Servus Welt', 'explanation': 'Austrian'},
          ],
        }),
      );
      final result = await repository.getAlternatives(
        await engineOf(gemma),
        englishToGerman,
        'Hallo Welt',
      );
      expect(result.alternatives.single.text, 'Servus Welt');
      final request =
          verify(() => clientOf(gemma).chat(captureAny())).captured.single
              as LlmRequest;
      expect(request.jsonOutput, isTrue);
      // Left to the client: the catalogue entry's sampling.
      expect(request.temperature, isNull);
      expect(request.topP, isNull);
      verifyZeroInteractions(mozhi);
    });

    test('translations get the default temperature only', () async {
      stubStream(gemma, ['Hallo']);
      await repository
          .translate(await engineOf(gemma), englishToGerman)
          .drain<void>();
      final request = capturedStream(gemma);
      expect(request.temperature, TranslationRepository.defaultAiTemperature);
      expect(request.topP, isNull);
      expect(request.topK, isNull);
      expect(request.repeatPenalty, isNull);
    });
  });

  group('chunks', () {
    /// [count] paragraphs of [length] + 1 characters.
    String paragraphs(int count, int length) =>
        List.generate(count, (i) => '${'$i' * length}.').join('\n\n');

    test('are at most onDeviceAiChunkThreshold characters', () async {
      expect(TranslationRepository.defaultOnDeviceAiChunkThreshold, 1200);
      stubStream(hyMt, ['Teil']);
      // 1604 characters: one part for a local server (2500), two on the
      // device (1200).
      await repository
          .translate(
            await engineOf(hyMt),
            englishToGerman.copyWith(text: paragraphs(2, 800)),
          )
          .drain<void>();
      verify(() => clientOf(hyMt).streamChat(any())).called(2);
    });

    test('the threshold can be set and must be positive', () async {
      repository = newRepository(onDeviceAiChunkThreshold: 5000);
      configure();
      stubStream(hyMt, ['Teil']);
      await repository
          .translate(
            await engineOf(hyMt),
            englishToGerman.copyWith(text: paragraphs(2, 800)),
          )
          .drain<void>();
      verify(() => clientOf(hyMt).streamChat(any())).called(1);
      expect(
        () => TranslationRepository(onDeviceAiChunkThreshold: 0),
        throwsRangeError,
      );
    });
  });

  group('warmUp', () {
    test('loads the model, also in Offline only', () async {
      when(() => clientOf(gemma).warmUp(any())).thenAnswer((_) async => true);
      expect(await repository.warmUp(await engineOf(gemma)), isTrue);
      verify(() => clientOf(gemma).warmUp('gemma-4-e2b-q4')).called(1);
    });

    test('is false when loading fails', () async {
      when(() => clientOf(gemma).warmUp(any())).thenThrow(StateError('none'));
      expect(await repository.warmUp(await engineOf(gemma)), isFalse);
    });

    test('a local server is still refused in Offline only', () async {
      configure([ollamaConfig, gemma]);
      final engine = (await repository.getEngines()).first;
      expect(engine.providerId, ollamaConfig.id);
      expect(
        repository.needsConsent(engine, source: english, target: german),
        isTrue,
      );
      expect(await repository.warmUp(engine), isFalse);
      expect(endpoints, isEmpty);
    });
  });

  test('testProvider uses the MT prompt and sampling', () async {
    when(() => clientOf(hyMt).chat(any())).thenAnswer((_) async => 'Bonjour');
    expect(await repository.testProvider(hyMt), 'Bonjour');
    final request =
        verify(() => clientOf(hyMt).chat(captureAny())).captured.single
            as LlmRequest;
    expect(request.messages.single.content, startsWith('Translate the'));
    expect(request.topK, 20);
    expect(request.repeatPenalty, 1.05);
  });
}
