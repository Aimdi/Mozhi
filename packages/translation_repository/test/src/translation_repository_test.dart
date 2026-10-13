import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  late Map<String, MockMozhiApiClient> mozhi;
  late List<Uri> mozhiBuilt;
  late Map<String, MockLlmClient> llm;
  late List<MockLlmClient> llmQueue;
  late List<LlmEndpoint> llmBuilt;
  late MockDeeplClient deepl;
  late MockLibreTranslateClient libre;
  late List<AiProviderConfig> mtBuilt;
  late TranslationRepository repository;

  MockMozhiApiClient a() => mozhi[instanceA.url]!;
  MockMozhiApiClient b() => mozhi[instanceB.url]!;
  MockMozhiApiClient c() => mozhi[instanceC.url]!;
  MockLlmClient llmOf(AiProviderConfig config) =>
      llm[Uri.parse(config.baseUrl).host]!;

  void configure({
    List<MozhiInstance> instances = const [instanceA, instanceB],
    List<AiProviderConfig> providers = const [
      claudeConfig,
      ollamaConfig,
      disabledConfig,
    ],
  }) => repository.updateConfiguration(
    instances: instances,
    providers: providers,
  );

  TranslationRepository newRepository({
    OfflineTranslator? offline,
    TranslationCache? cache,
  }) => TranslationRepository(
    mozhiClientFactory: (uri) {
      mozhiBuilt.add(uri);
      return mozhi[uri.toString()]!;
    },
    llmClientFactory: (endpoint) {
      llmBuilt.add(endpoint);
      return llmQueue.isNotEmpty
          ? llmQueue.removeAt(0)
          : llm[endpoint.baseUrl.host]!;
    },
    deeplClientFactory: (config) {
      mtBuilt.add(config);
      return deepl;
    },
    libreTranslateClientFactory: (config) {
      mtBuilt.add(config);
      return libre;
    },
    offline: offline,
    cache: cache,
    snapshotInterval: Duration.zero,
  );

  setUp(() {
    mozhi = {
      for (final instance in [instanceA, instanceB, instanceC])
        instance.url: MockMozhiApiClient(),
    };
    mozhiBuilt = [];
    llm = {
      for (final config in [
        claudeConfig,
        openAiConfig,
        ollamaConfig,
        disabledConfig,
        gemmaConfig,
        cloudGemmaConfig,
      ])
        Uri.parse(config.baseUrl).host: MockLlmClient(),
    };
    llmQueue = [];
    llmBuilt = [];
    deepl = MockDeeplClient();
    libre = MockLibreTranslateClient();
    mtBuilt = [];
    repository = newRepository();
  });

  // stubs

  void stubEngines(MockMozhiApiClient client, Map<String, String> engines) =>
      when(client.getEngines).thenAnswer((_) async => engines);

  void stubEnginesError(MockMozhiApiClient client, Object error) =>
      when(client.getEngines).thenThrow(error);

  When<Future<MozhiTranslation>> whenTranslate(MockMozhiApiClient client) =>
      when(
        () => client.translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      );

  When<Future<List<MozhiTranslation>>> whenBatch(MockMozhiApiClient client) =>
      when(
        () => client.translateWithEngines(
          engines: any(named: 'engines'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      );

  When<Future<Uint8List>> whenTts(MockMozhiApiClient client, String engine) =>
      when(
        () => client.textToSpeech(
          engine: any(named: 'engine', that: equals(engine)),
          language: any(named: 'language'),
          text: any(named: 'text'),
        ),
      );

  void stubStream(MockLlmClient client, List<String> deltas) =>
      when(() => client.streamChat(any()))
          .thenAnswer((_) => Stream.fromIterable(deltas));

  void stubChat(MockLlmClient client, List<String> outputs) {
    final queue = [...outputs];
    when(
      () => client.chat(any()),
    ).thenAnswer((_) async => queue.length > 1 ? queue.removeAt(0) : queue[0]);
  }

  List<LlmRequest> capturedChats(MockLlmClient client) =>
      verify(() => client.chat(captureAny())).captured.cast<LlmRequest>();

  LlmRequest capturedStream(MockLlmClient client) =>
      verify(() => client.streamChat(captureAny())).captured.single
          as LlmRequest;

  const autoToGerman = TranslationRequest(
    text: 'Hello world',
    source: Language.auto,
    target: german,
  );
  const englishToGerman = TranslationRequest(
    text: 'Hello world',
    source: english,
    target: german,
  );
  final claude = aiEngine(claudeConfig);
  final openAi = aiEngine(openAiConfig);

  // configuration

  group('default client factories', () {
    // Port 9 (discard) is closed on test machines: requests fail fast.
    test('create real Mozhi clients', () async {
      final repository = TranslationRepository();
      addTearDown(repository.dispose);
      await expectLater(
        repository.pingInstance(const MozhiInstance(url: 'http://127.0.0.1:9')),
        throwsA(isA<MozhiApiException>()),
      );
    });

    test('create real LLM clients', () async {
      final repository = TranslationRepository();
      addTearDown(repository.dispose);
      await expectLater(
        repository.listModels(
          openAiConfig.copyWith(baseUrl: 'http://127.0.0.1:9/v1'),
        ),
        throwsA(isA<LlmApiException>()),
      );
    });
  });

  group('configuration', () {
    test('starts empty', () {
      expect(repository.instances, isEmpty);
      expect(repository.providers, isEmpty);
      expect(repository.activeInstance, isNull);
    });

    test('exposes the configured instances and providers', () {
      configure();
      expect(repository.instances, [instanceA, instanceB]);
      expect(repository.providers, [
        claudeConfig,
        ollamaConfig,
        disabledConfig,
      ]);
      expect(repository.activeInstance, instanceA);
    });

    test('closes Mozhi clients of removed instances', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      await repository.getEngines();
      configure(instances: [instanceB]);
      verify(a().close).called(1);
      expect(repository.activeInstance, instanceB);
    });

    test('closes LLM clients of removed providers', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Hallo']);
      await repository.translate(claude, englishToGerman).drain<void>();
      configure(providers: [ollamaConfig]);
      verify(llmOf(claudeConfig).close).called(1);
    });

    test('replaces the LLM client when the connection changes', () async {
      final first = MockLlmClient();
      final second = MockLlmClient();
      llmQueue.addAll([first, second]);
      stubStream(first, ['Hallo']);
      stubStream(second, ['Hallo']);
      configure(providers: [claudeConfig]);
      await repository.translate(claude, englishToGerman).drain<void>();
      await repository.translate(claude, englishToGerman).drain<void>();
      expect(llmBuilt, hasLength(1));

      configure(providers: [claudeConfig.copyWith(apiKey: 'rotated')]);
      verify(first.close).called(1);
      await repository.translate(claude, englishToGerman).drain<void>();
      expect(llmBuilt, hasLength(2));
      expect(llmBuilt.last.apiKey, 'rotated');
      verify(() => second.streamChat(any())).called(1);
    });

    test('keeps the LLM client when only the model changes', () async {
      configure(providers: [claudeConfig]);
      stubStream(llmOf(claudeConfig), ['Hallo']);
      await repository.translate(claude, englishToGerman).drain<void>();
      configure(providers: [claudeConfig.copyWith(model: 'claude-haiku-5-5')]);
      await repository.translate(claude, englishToGerman).drain<void>();
      expect(llmBuilt, hasLength(1));
      verifyNever(llmOf(claudeConfig).close);
      final requests = verify(
        () => llmOf(claudeConfig).streamChat(captureAny()),
      ).captured.cast<LlmRequest>();
      expect(requests.map((r) => r.model), [
        'claude-opus-5-5',
        'claude-haiku-5-5',
      ]);
    });

    test('dispose closes every cached client', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      stubStream(llmOf(claudeConfig), ['Hallo']);
      await repository.getEngines();
      await repository.translate(claude, englishToGerman).drain<void>();
      repository.dispose();
      verify(a().close).called(1);
      verify(llmOf(claudeConfig).close).called(1);
    });
  });

  // getEngines

  group('getEngines', () {
    test('lists Mozhi engines then enabled AI providers', () async {
      configure();
      stubEngines(a(), {'deepl': 'DeepL', 'google': 'Google'});
      final engines = await repository.getEngines();
      expect(engines.map((e) => e.id), [
        'mozhi:deepl',
        'mozhi:google',
        'ai:claude',
        'ai:ollama',
      ]);

      final deepl = engines.first;
      expect(deepl.kind, EngineKind.mozhi);
      expect(deepl.name, 'DeepL');
      expect(deepl.mozhiEngine, 'deepl');
      expect(deepl.subtitle, instanceA.displayName);
      expect(deepl.providerId, isNull);

      final ai = engines[2];
      expect(ai.kind, EngineKind.ai);
      expect(ai.name, 'Claude');
      expect(ai.subtitle, 'claude-opus-5-5');
      expect(ai.providerId, 'claude');
      expect(ai.isLocal, claudeConfig.isLocal);
      expect(engines.last.isLocal, ollamaConfig.isLocal);
      expect(engines.last.isLocal, isTrue);
    });

    test('falls back to the engine id for empty names', () async {
      configure(providers: []);
      stubEngines(a(), {'libre': ''});
      final engines = await repository.getEngines();
      expect(engines.single.name, 'libre');
      expect(engines.single.mozhiEngine, 'libre');
    });

    test('caches the Mozhi engine list', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      await repository.getEngines();
      final again = await repository.getEngines();
      expect(again.first.id, 'mozhi:google');
      verify(a().getEngines).called(1);
    });

    test('shares one request between concurrent calls', () async {
      configure();
      final completer = Completer<Map<String, String>>();
      when(a().getEngines).thenAnswer((_) => completer.future);
      final first = repository.getEngines();
      final second = repository.getEngines();
      completer.complete({'google': 'Google'});
      expect((await first).first.id, 'mozhi:google');
      expect((await second).first.id, 'mozhi:google');
      verify(a().getEngines).called(1);
    });

    test('refresh bypasses the cache', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      await repository.getEngines();
      stubEngines(a(), {'google': 'Google', 'deepl': 'DeepL'});
      final engines = await repository.getEngines(refresh: true);
      expect(engines.where((e) => e.isMozhi), hasLength(2));
      verify(a().getEngines).called(2);
    });

    test('reflects provider changes without refetching', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      await repository.getEngines();
      configure(providers: [openAiConfig]);
      final engines = await repository.getEngines();
      expect(engines.map((e) => e.id), ['mozhi:google', 'ai:openai']);
      verify(a().getEngines).called(1);
    });

    test('clears the cache when the instances change', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      stubEngines(c(), {'deepl': 'DeepL'});
      await repository.getEngines();
      configure();
      await repository.getEngines();
      verify(a().getEngines).called(1);

      configure(instances: [instanceC]);
      final engines = await repository.getEngines();
      expect(engines.first.id, 'mozhi:deepl');
      expect(engines.first.subtitle, instanceC.displayName);
    });

    test('fails over to the next instance and remembers it', () async {
      configure();
      stubEnginesError(a(), serverError());
      stubEngines(b(), {'google': 'Google'});
      final engines = await repository.getEngines();
      expect(engines.first.subtitle, instanceB.displayName);
      expect(engines.first.subtitle, 'b.example');
      expect(repository.activeInstance, instanceB);
    });

    test('refetches when another call moved the active instance', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      stubEngines(b(), {'deepl': 'DeepL'});
      expect((await repository.getEngines()).first.id, 'mozhi:google');

      whenTranslate(a()).thenThrow(serverError());
      whenTranslate(b()).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'google', translatedText: 'Hallo'),
      );
      await repository.translate(googleEngine, englishToGerman).drain<void>();
      expect(repository.activeInstance, instanceB);

      final engines = await repository.getEngines();
      expect(engines.first.id, 'mozhi:deepl');
      expect(engines.first.subtitle, instanceB.displayName);
      await repository.getEngines();
      verify(b().getEngines).called(1);
      verify(a().getEngines).called(1);
    });

    test('returns only AI engines when no instance is reachable', () async {
      configure();
      stubEnginesError(a(), serverError());
      stubEnginesError(b(), const MozhiApiException('offline'));
      final engines = await repository.getEngines();
      expect(engines.map((e) => e.id), ['ai:claude', 'ai:ollama']);
    });

    test('does not cache failures', () async {
      configure();
      stubEnginesError(a(), serverError());
      stubEnginesError(b(), serverError());
      await repository.getEngines();
      stubEngines(a(), {'google': 'Google'});
      final engines = await repository.getEngines();
      expect(engines.first.id, 'mozhi:google');
    });

    test('throws the last error when nothing is available', () async {
      configure(providers: [disabledConfig]);
      stubEnginesError(a(), serverError('a down'));
      stubEnginesError(b(), serverError('b down'));
      await expectLater(
        repository.getEngines(),
        throwsA(
          isA<MozhiApiException>().having(
            (e) => e.message,
            'message',
            'b down',
          ),
        ),
      );
    });

    test('lists AI engines without touching Mozhi when no instance is '
        'configured', () async {
      configure(instances: []);
      final engines = await repository.getEngines();
      expect(engines.map((e) => e.id), ['ai:claude', 'ai:ollama']);
      expect(mozhiBuilt, isEmpty);
    });

    test('returns an empty list when nothing is configured', () async {
      expect(await repository.getEngines(), isEmpty);
    });

    test('caches the list under the instance that answered', () async {
      configure();
      stubEnginesError(a(), serverError());
      stubEngines(b(), {'deepl': 'DeepL'});
      await repository.getEngines();
      expect(repository.activeInstance, instanceB);

      // B goes down and a translation fails back over to A.
      whenTranslate(b()).thenThrow(serverError());
      whenTranslate(a()).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'google', translatedText: 'Hallo'),
      );
      await repository.translate(googleEngine, englishToGerman).drain<void>();
      expect(repository.activeInstance, instanceA);

      stubEngines(a(), {'google': 'Google'});
      final engines = await repository.getEngines();
      expect(engines.first.id, 'mozhi:google');
      expect(engines.first.subtitle, instanceA.displayName);
    });

    test('refresh starts at the first instance again', () async {
      configure();
      stubEnginesError(a(), serverError());
      stubEngines(b(), {'deepl': 'DeepL'});
      await repository.getEngines();
      expect(repository.activeInstance, instanceB);

      stubEngines(a(), {'google': 'Google'});
      final engines = await repository.getEngines(refresh: true);
      expect(engines.first.id, 'mozhi:google');
      expect(repository.activeInstance, instanceA);
    });

    test('resetActiveInstance forgets the failover choice', () async {
      configure();
      stubEnginesError(a(), serverError());
      stubEngines(b(), {'deepl': 'DeepL'});
      await repository.getEngines();
      expect(repository.activeInstance, instanceB);
      repository.resetActiveInstance();
      expect(repository.activeInstance, instanceA);
    });

    test('reordering the instances moves requests to the new first one', () async {
      configure(instances: [instanceA, instanceB]);
      stubEngines(a(), {'google': 'Google'});
      stubEngines(b(), {'deepl': 'DeepL'});
      await repository.getEngines();
      configure(instances: [instanceB, instanceA]);
      expect(repository.activeInstance, instanceB);
      final engines = await repository.getEngines();
      expect(engines.first.subtitle, instanceB.displayName);
    });

    test('lists machine translation services and the offline engine', () async {
      repository = newRepository(offline: FakeOfflineTranslator());
      configure(
        instances: [],
        providers: [deeplConfig, gemmaConfig, libreConfig, claudeConfig],
      );
      final engines = await repository.getEngines();
      expect(engines.map((e) => e.id), [
        'mt:deepl',
        'ai:gemma',
        'mt:libre',
        'ai:claude',
        'offline:mlkit',
      ]);
      final byId = {for (final e in engines) e.id: e};

      final deepl = byId['mt:deepl']!;
      expect(deepl.kind, EngineKind.mt);
      expect(deepl.isMt, isTrue);
      expect(deepl.mtService, MtService.deepl);
      expect(deepl.providerId, 'deepl');
      expect(deepl.subtitle, 'DeepL API');
      expect(deepl.isLocal, isFalse);
      expect(deepl.supportsFormality, isTrue);
      expect(deepl.supportsOptions, isFalse);

      final libre = byId['mt:libre']!;
      expect(libre.mtService, MtService.libreTranslate);
      expect(libre.subtitle, 'localhost');
      expect(libre.isLocal, isTrue);
      expect(libre.supportsFormality, isFalse);

      final gemma = byId['ai:gemma']!;
      expect(gemma.promptProfile, PromptProfile.translateGemma);
      expect(gemma.usesMtProfile, isTrue);
      expect(gemma.supportsExtras, isFalse);
      expect(gemma.supportsCustomLanguages, isFalse);
      expect(byId['ai:claude']!.promptProfile, PromptProfile.general);
      expect(byId['ai:claude']!.supportsExtras, isTrue);

      final offline = byId['offline:mlkit']!;
      expect(offline, TranslationEngine.offline());
      expect(offline.isOffline, isTrue);
      expect(offline.isLocal, isTrue);
      expect(offline.name, 'Offline (on-device)');
      expect(repository.hasOfflineEngine, isTrue);
    });

    test('uses the host of a custom service URL as subtitle', () async {
      configure(
        instances: [],
        providers: [deeplConfig.copyWith(baseUrl: 'deepl-proxy.example/')],
      );
      final engines = await repository.getEngines();
      expect(engines.single.subtitle, 'deepl-proxy.example');
    });

    test('leaves out an unavailable offline translator', () async {
      repository = newRepository(
        offline: FakeOfflineTranslator(isAvailable: false),
      );
      expect(await repository.getEngines(), isEmpty);
      expect(repository.hasOfflineEngine, isFalse);
    });

    test('keeps the offline engine when no instance is reachable', () async {
      repository = newRepository(offline: FakeOfflineTranslator());
      configure(providers: []);
      stubEnginesError(a(), serverError());
      stubEnginesError(b(), serverError());
      final engines = await repository.getEngines();
      expect(engines.single.id, 'offline:mlkit');
    });
  });

  // languages

  group('languages', () {
    test('maps Mozhi source languages with auto first', () async {
      configure();
      when(() => a().getSourceLanguages('google')).thenAnswer(
        (_) async => const [
          MozhiLanguage(id: 'de', name: 'German'),
          MozhiLanguage(id: 'auto', name: 'Detect'),
          MozhiLanguage(id: 'en', name: 'English'),
        ],
      );
      final languages = await repository.getSourceLanguages(googleEngine);
      expect(languages, [Language.auto, german, english]);
      expect(languages[1].name, 'German');
      expect(languages[1].nativeName, LanguageCatalog.byCode('de')?.nativeName);
    });

    test('maps Mozhi target languages', () async {
      configure();
      when(() => a().getTargetLanguages('deepl')).thenAnswer(
        (_) async => const [MozhiLanguage(id: 'fr', name: 'French')],
      );
      expect(await repository.getTargetLanguages(deeplEngine), [french]);
    });

    test('caches per instance, engine and direction', () async {
      configure();
      when(() => a().getSourceLanguages(any()))
          .thenAnswer((_) async => const [MozhiLanguage(id: 'en', name: 'En')]);
      when(() => a().getTargetLanguages(any()))
          .thenAnswer((_) async => const [MozhiLanguage(id: 'de', name: 'De')]);
      await repository.getSourceLanguages(googleEngine);
      await repository.getSourceLanguages(googleEngine);
      await repository.getTargetLanguages(googleEngine);
      await repository.getTargetLanguages(googleEngine);
      await repository.getSourceLanguages(deeplEngine);
      verify(() => a().getSourceLanguages('google')).called(1);
      verify(() => a().getTargetLanguages('google')).called(1);
      verify(() => a().getSourceLanguages('deepl')).called(1);
    });

    test('getEngines(refresh: true) clears the language cache', () async {
      configure();
      stubEngines(a(), {'google': 'Google'});
      when(() => a().getSourceLanguages(any()))
          .thenAnswer((_) async => const [MozhiLanguage(id: 'en', name: 'En')]);
      await repository.getSourceLanguages(googleEngine);
      await repository.getEngines(refresh: true);
      await repository.getSourceLanguages(googleEngine);
      verify(() => a().getSourceLanguages('google')).called(2);
    });

    test('a changed instance list clears the language cache', () async {
      configure();
      when(() => a().getSourceLanguages(any()))
          .thenAnswer((_) async => const [MozhiLanguage(id: 'en', name: 'En')]);
      await repository.getSourceLanguages(googleEngine);
      configure(instances: [instanceA, instanceC]);
      await repository.getSourceLanguages(googleEngine);
      verify(() => a().getSourceLanguages('google')).called(2);
    });

    test('fails over and does not cache failures', () async {
      configure();
      when(() => a().getSourceLanguages(any())).thenThrow(serverError());
      when(() => b().getSourceLanguages(any())).thenThrow(serverError());
      await expectLater(
        repository.getSourceLanguages(googleEngine),
        throwsA(isA<MozhiApiException>()),
      );
      when(() => b().getSourceLanguages(any()))
          .thenAnswer((_) async => const [MozhiLanguage(id: 'en', name: 'En')]);
      expect(await repository.getSourceLanguages(googleEngine), [english]);
      expect(repository.activeInstance, instanceB);
    });

    test('maps DeepL targets Mozhi cannot translate into', () async {
      configure();
      when(() => a().getTargetLanguages('deepl')).thenAnswer(
        (_) async => const [
          MozhiLanguage(id: 'de', name: 'German'),
          MozhiLanguage(id: 'en', name: 'English'),
          MozhiLanguage(id: 'en-gb', name: 'English (British)'),
          MozhiLanguage(id: 'en-us', name: 'English (American)'),
          MozhiLanguage(id: 'pt-br', name: 'Portuguese (Brazilian)'),
          MozhiLanguage(id: 'pt-pt', name: 'Portuguese (European)'),
          MozhiLanguage(id: 'zh-hans', name: 'Chinese (simplified)'),
          MozhiLanguage(id: 'zh-hant', name: 'Chinese (traditional)'),
        ],
      );
      final languages = await repository.getTargetLanguages(deeplEngine);
      expect(languages.map((l) => l.code), ['de', 'en', 'pt', 'zh']);
      expect(languages[1].name, 'English');
      expect(languages[2].name, LanguageCatalog.byCode('pt')!.name);
      expect(languages[3].name, LanguageCatalog.byCode('zh')!.name);
    });

    test('keeps DeepL source lists and other engines unchanged', () async {
      configure();
      const list = [MozhiLanguage(id: 'en-us', name: 'English (American)')];
      when(() => a().getSourceLanguages('deepl'))
          .thenAnswer((_) async => list);
      when(() => a().getTargetLanguages('google'))
          .thenAnswer((_) async => list);
      expect(
        (await repository.getSourceLanguages(deeplEngine)).single.code,
        'en-us',
      );
      expect(
        (await repository.getTargetLanguages(googleEngine)).single.code,
        'en-us',
      );
    });

    test('AI engines use the catalogue', () async {
      expect(await repository.getSourceLanguages(claude), [
        Language.auto,
        ...LanguageCatalog.all,
      ]);
      expect(await repository.getTargetLanguages(claude), LanguageCatalog.all);
      expect(mozhiBuilt, isEmpty);
    });
  });

  // translate (Mozhi)

  group('translate with Mozhi', () {
    const translation = MozhiTranslation(
      engine: 'google',
      translatedText: 'Hallo Welt',
      detectedLanguage: 'en',
      targetTransliteration: 'ha-lo',
      targetSynonyms: ['Servus'],
      wordChoices: [MozhiWordChoice(word: 'Hallo', definition: 'greeting')],
    );

    test('returns one complete mapped result', () async {
      configure();
      whenTranslate(a()).thenAnswer((_) async => translation);
      final results = await repository
          .translate(googleEngine, autoToGerman)
          .toList();
      final result = results.single;
      expect(result.engineId, 'mozhi:google');
      expect(result.engineName, 'Google');
      expect(result.text, 'Hallo Welt');
      expect(result.isComplete, isTrue);
      expect(result.detectedSource, 'en');
      expect(result.targetTransliteration, 'ha-lo');
      expect(result.targetSynonyms, ['Servus']);
      expect(result.wordChoices.single.word, 'Hallo');
      expect(result.elapsed, isNotNull);
      verify(
        () => a().translate(
          engine: 'google',
          from: 'auto',
          to: 'de',
          text: 'Hello world',
        ),
      ).called(1);
    });

    test('normalises the detected language', () async {
      configure();
      whenTranslate(a()).thenAnswer(
        (_) async => const MozhiTranslation(
          engine: 'google',
          translatedText: 'Hallo',
          detectedLanguage: 'iw',
        ),
      );
      final result = await repository
          .translate(googleEngine, autoToGerman)
          .single;
      expect(result.detectedSource, 'he');
    });

    test('reports no detected language for empty values', () async {
      configure();
      whenTranslate(a()).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'google', translatedText: 'Hallo'),
      );
      final result = await repository
          .translate(googleEngine, autoToGerman)
          .single;
      expect(result.detectedSource, isNull);
    });

    test('emits nothing for empty input', () async {
      configure();
      await expectLater(
        repository.translate(
          googleEngine,
          autoToGerman.copyWith(text: '  \n '),
        ),
        emitsDone,
      );
      expect(mozhiBuilt, isEmpty);
    });

    test('rejects custom target languages', () async {
      configure();
      await expectLater(
        repository.translate(
          googleEngine,
          autoToGerman.copyWith(target: const Language.custom('Pirate')),
        ),
        emitsError(isArgumentError),
      );
      expect(mozhiBuilt, isEmpty);
    });

    test('fails over and keeps using the instance that worked', () async {
      configure(instances: [instanceA, instanceB, instanceC]);
      whenTranslate(a()).thenThrow(serverError());
      whenTranslate(b()).thenThrow(const MozhiApiException('refused'));
      whenTranslate(c()).thenAnswer((_) async => translation);
      await repository.translate(googleEngine, autoToGerman).drain<void>();
      await repository
          .translate(googleEngine, autoToGerman, refresh: true)
          .drain<void>();
      verify(
        () => a().translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      ).called(1);
      verify(
        () => c().translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      ).called(2);
      expect(repository.activeInstance, instanceC);
    });

    test('throws non-retryable errors without failing over', () async {
      configure();
      whenTranslate(a()).thenThrow(badRequest('invalid language'));
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(
          isA<MozhiApiException>().having((e) => e.statusCode, 'status', 400),
        ),
      );
      verifyZeroInteractions(b());
    });

    test('throws the last error when every instance fails', () async {
      configure();
      whenTranslate(a()).thenThrow(serverError('a'));
      whenTranslate(b()).thenThrow(serverError('b'));
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(
          isA<MozhiApiException>().having((e) => e.message, 'message', 'b'),
        ),
      );
    });

    test('throws when no instance is configured', () async {
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(isA<MozhiApiException>()),
      );
    });

    test('does not re-send the text after a timeout', () async {
      configure();
      whenTranslate(a()).thenThrow(
        const MozhiApiException('No response within 30000 ms'),
      );
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(isA<MozhiApiException>()),
      );
      whenTranslate(a()).thenThrow(TimeoutException('slow'));
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(isA<TimeoutException>()),
      );
      verifyZeroInteractions(b());
    });

    test('treats an empty translation as a failure and fails over', () async {
      configure();
      whenTranslate(a()).thenAnswer(
        (_) async => const MozhiTranslation(engine: 'deepl', translatedText: ' '),
      );
      whenTranslate(b()).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'deepl', translatedText: 'Hallo'),
      );
      final result = await repository
          .translate(deeplEngine, englishToGerman)
          .single;
      expect(result.text, 'Hallo');
      expect(repository.activeInstance, instanceB);
    });

    test('reports an empty translation from every instance', () async {
      configure();
      for (final client in [a(), b()]) {
        whenTranslate(client).thenAnswer(
          (_) async => const MozhiTranslation(engine: 'deepl', translatedText: ''),
        );
      }
      await expectLater(
        repository.translate(deeplEngine, englishToGerman),
        emitsError(
          isA<MozhiApiException>()
              .having(
                (e) => e.message,
                'message',
                'DeepL returned an empty translation.',
              )
              .having((e) => e.statusCode, 'statusCode', 502),
        ),
      );
    });

    test('does not fail over on input errors the server reports as 500', () async {
      configure();
      whenTranslate(a()).thenThrow(
        const MozhiApiException('Target language code invalid', statusCode: 500),
      );
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(isA<MozhiApiException>()),
      );
      verifyZeroInteractions(b());
    });

    test('removes upstream URLs with the user text from errors', () async {
      configure();
      for (final client in [a(), b()]) {
        whenTranslate(client).thenThrow(
          const MozhiApiException(
            'Get "https://api.mymemory.translated.net/get?q=Hello+world": '
            'Forbidden',
            statusCode: 500,
          ),
        );
      }
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(
          isA<MozhiApiException>().having(
            (e) => e.message,
            'message',
            'Get "https://api.mymemory.translated.net": Forbidden',
          ),
        ),
      );
    });

    test('sends DeepL regional targets as the base code', () async {
      configure();
      whenTranslate(a()).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'deepl', translatedText: 'Hi'),
      );
      await repository
          .translate(
            deeplEngine,
            englishToGerman.copyWith(
              target: const Language(code: 'en-US', name: 'English (US)'),
            ),
          )
          .drain<void>();
      verify(
        () => a().translate(
          engine: 'deepl',
          from: 'en',
          to: 'en',
          text: 'Hello world',
        ),
      ).called(1);
    });
  });

  // cache

  group('cache', () {
    const translation = MozhiTranslation(
      engine: 'google',
      translatedText: 'Hallo Welt',
    );

    test('serves repeated translations from the cache', () async {
      configure();
      whenTranslate(a()).thenAnswer((_) async => translation);
      final first = await repository.translate(googleEngine, autoToGerman).single;
      final second = await repository
          .translate(googleEngine, autoToGerman)
          .single;
      expect(second, first);
      verify(
        () => a().translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      ).called(1);
    });

    test('caches only the final AI result', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Hal', 'lo']);
      final streamed = await repository
          .translate(claude, englishToGerman)
          .toList();
      expect(streamed, hasLength(3));
      final cached = await repository.translate(claude, englishToGerman).toList();
      expect(cached.single, streamed.last);
      verify(() => llmOf(claudeConfig).streamChat(any())).called(1);
    });

    test('refresh skips the lookup and stores the new result', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Hallo']);
      await repository.translate(claude, englishToGerman).drain<void>();
      stubStream(llmOf(claudeConfig), ['Servus']);
      final refreshed = await repository
          .translate(claude, englishToGerman, refresh: true)
          .last;
      expect(refreshed.text, 'Servus');
      final cached = await repository.translate(claude, englishToGerman).single;
      expect(cached.text, 'Servus');
    });

    test('clearCache forgets every result', () async {
      configure();
      whenTranslate(a()).thenAnswer((_) async => translation);
      await repository.translate(googleEngine, autoToGerman).drain<void>();
      repository.clearCache();
      await repository.translate(googleEngine, autoToGerman).drain<void>();
      verify(
        () => a().translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      ).called(2);
    });

    test('a changed provider drops its cached results only', () async {
      configure(providers: [claudeConfig, openAiConfig]);
      stubStream(llmOf(claudeConfig), ['Hallo']);
      stubStream(llmOf(openAiConfig), ['Hallo']);
      await repository.translate(claude, englishToGerman).drain<void>();
      await repository.translate(openAi, englishToGerman).drain<void>();
      configure(
        providers: [claudeConfig.copyWith(temperature: 0.9), openAiConfig],
      );
      await repository.translate(claude, englishToGerman).drain<void>();
      await repository.translate(openAi, englishToGerman).drain<void>();
      verify(() => llmOf(claudeConfig).streamChat(any())).called(2);
      verify(() => llmOf(openAiConfig).streamChat(any())).called(1);
    });

    test('never caches failures', () async {
      configure();
      whenTranslate(a()).thenThrow(badRequest());
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(isA<MozhiApiException>()),
      );
      whenTranslate(a()).thenAnswer((_) async => translation);
      final result = await repository
          .translate(googleEngine, autoToGerman)
          .single;
      expect(result.text, 'Hallo Welt');
    });

    test('can be disabled', () async {
      repository = newRepository(cache: TranslationCache(maxEntries: 0));
      configure();
      whenTranslate(a()).thenAnswer((_) async => translation);
      await repository.translate(googleEngine, autoToGerman).drain<void>();
      await repository.translate(googleEngine, autoToGerman).drain<void>();
      verify(
        () => a().translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      ).called(2);
    });

    test('dispose empties the cache', () async {
      final cache = TranslationCache();
      repository = newRepository(cache: cache);
      configure();
      whenTranslate(a()).thenAnswer((_) async => translation);
      await repository.translate(googleEngine, autoToGerman).drain<void>();
      expect(cache.length, 1);
      repository.dispose();
      expect(cache.isEmpty, isTrue);
    });
  });

  // translate (AI)

  group('translate with AI', () {
    test(
      'sends the translation prompt without temperature to Anthropic',
      () async {
        configure();
        stubStream(llmOf(claudeConfig), ['Hallo Welt']);
        await repository.translate(claude, autoToGerman).drain<void>();
        final request = capturedStream(llmOf(claudeConfig));
        expect(request.model, 'claude-opus-5-5');
        expect(request.messages, TranslationPrompts.translate(autoToGerman));
        expect(request.temperature, isNull);
        expect(request.effort, 'low');
        expect(request.jsonOutput, isFalse);
      },
    );

    test('sends the temperature to other providers', () async {
      configure(providers: [openAiConfig]);
      stubStream(llmOf(openAiConfig), ['Hallo Welt']);
      await repository.translate(openAi, autoToGerman).drain<void>();
      final request = capturedStream(llmOf(openAiConfig));
      expect(request.model, 'gpt-x');
      expect(request.temperature, 0.3);
      expect(request.effort, 'medium');
    });

    test('streams snapshots, hides the marker and completes', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['[[la', 'ng:de]]\nHal', 'lo']);
      final results = await repository
          .translate(claude, autoToGerman.copyWith(text: 'Hallo'))
          .toList();
      expect(results.map((r) => r.text), ['Hal', 'Hallo', 'Hallo']);
      expect(results.map((r) => r.isComplete), [false, false, true]);
      expect(results.map((r) => r.detectedSource), everyElement('de'));
      expect(results.map((r) => r.engineId), everyElement('ai:claude'));
      expect(results.map((r) => r.text), everyElement(isNot(contains('['))));
    });

    test('forwards provider errors as-is', () async {
      configure();
      when(
        () => llmOf(claudeConfig).streamChat(any()),
      ).thenAnswer((_) => Stream.error(const LlmRefusalException('declined')));
      await expectLater(
        repository.translate(claude, autoToGerman),
        emitsError(isA<LlmRefusalException>()),
      );
    });

    test('cancelling cancels the provider stream', () async {
      configure();
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => deltas.stream);
      final results = <TranslationResult>[];
      final subscription = repository
          .translate(claude, englishToGerman)
          .listen(results.add);
      await pumpEventQueue();
      deltas.controller.add('Hal');
      await pumpEventQueue();
      await subscription.cancel();
      expect(deltas.cancelled, isTrue);
      expect(results.single.text, 'Hal');
    });

    test('pausing pauses the provider stream', () async {
      configure();
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => deltas.stream);
      final subscription = repository
          .translate(claude, englishToGerman)
          .listen((_) {});
      await pumpEventQueue();
      subscription.pause();
      expect(deltas.controller.isPaused, isTrue);
      subscription.resume();
      expect(deltas.controller.isPaused, isFalse);
      await subscription.cancel();
    });

    test('applies refinement instructions through the prompt', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Guten Tag, Welt']);
      final request = englishToGerman.copyWith(
        options: const TranslationOptions(instructions: 'More formal.'),
      );
      await repository.translate(claude, request).drain<void>();
      expect(
        capturedStream(llmOf(claudeConfig)).messages,
        TranslationPrompts.translate(request),
      );
    });

    test('emits nothing for empty input', () async {
      configure();
      await expectLater(
        repository.translate(claude, autoToGerman.copyWith(text: ' ')),
        emitsDone,
      );
      expect(llmBuilt, isEmpty);
    });

    test('rejects engines of unknown providers', () async {
      configure();
      await expectLater(
        repository.translate(openAi, autoToGerman),
        emitsError(isArgumentError),
      );
    });

    test('resolves the provider from the engine id', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Hallo']);
      const engine = TranslationEngine(
        id: 'ai:claude',
        kind: EngineKind.ai,
        name: 'Claude',
      );
      final result = await repository.translate(engine, autoToGerman).last;
      expect(result.text, 'Hallo');
    });

    test('works with engines returned by getEngines', () async {
      configure(instances: []);
      stubStream(llmOf(ollamaConfig), ['Hallo']);
      final engines = await repository.getEngines();
      final ollama = engines.firstWhere((e) => e.providerId == 'ollama');
      final result = await repository.translate(ollama, autoToGerman).last;
      expect(result.isComplete, isTrue);
      expect(result.engineName, 'Local Qwen');
    });

    test('accepts custom target languages', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Ahoy, matey']);
      final request = englishToGerman.copyWith(
        target: const Language.custom('Pirate speak'),
      );
      final result = await repository.translate(claude, request).last;
      expect(result.text, 'Ahoy, matey');
      expect(
        capturedStream(llmOf(claudeConfig)).messages,
        TranslationPrompts.translate(request),
      );
    });
  });

  // compare

  group('compare', () {
    MozhiTranslation mozhiResult(String engine, String text) =>
        MozhiTranslation(engine: engine, translatedText: text);

    void stubMozhiEngines(MockMozhiApiClient client) =>
        whenTranslate(client).thenAnswer((invocation) async {
          final engine = invocation.namedArguments[#engine] as String;
          return MozhiTranslation(
            engine: engine,
            translatedText: 'Hallo ($engine)',
            detectedLanguage: 'iw',
          );
        });

    void verifyNoBatches(MockMozhiApiClient client) => verifyNever(
      () => client.translateWithEngines(
        engines: any(named: 'engines'),
        from: any(named: 'from'),
        to: any(named: 'to'),
        text: any(named: 'text'),
      ),
    );

    test('sends one single-engine request per Mozhi engine', () async {
      configure();
      stubMozhiEngines(a());
      stubStream(llmOf(claudeConfig), ['Hallo ', '(Claude)']);
      final entries = await repository.compare([
        googleEngine,
        deeplEngine,
        claude,
      ], englishToGerman).toList();

      expect(entries, hasLength(3));
      expect(entries.every((e) => e.isSuccess), isTrue);
      final byId = {for (final e in entries) e.id: e.result!};
      expect(byId['mozhi:google']!.text, 'Hallo (google)');
      expect(byId['mozhi:deepl']!.text, 'Hallo (deepl)');
      expect(byId['mozhi:deepl']!.engineName, 'DeepL');
      expect(byId['ai:claude']!.text, 'Hallo (Claude)');
      expect(byId['ai:claude']!.isComplete, isTrue);

      for (final engine in ['google', 'deepl']) {
        verify(
          () => a().translate(
            engine: engine,
            from: 'en',
            to: 'de',
            text: 'Hello world',
          ),
        ).called(1);
      }
      verifyNoBatches(a());
    });

    test('never sends engine=all or comma-separated lists', () async {
      configure();
      stubMozhiEngines(a());
      final engines = [
        for (final id in ['google', 'deepl', 'duckduckgo', 'yandex'])
          TranslationEngine.mozhi(id, id),
      ];
      final entries = await repository
          .compare(engines, englishToGerman)
          .toList();
      expect(entries, hasLength(4));
      final sent = verify(
        () => a().translate(
          engine: captureAny(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
        ),
      ).captured.cast<String>();
      expect(sent, unorderedEquals(['google', 'deepl', 'duckduckgo', 'yandex']));
      expect(sent, everyElement(isNot(anyOf(contains(','), equals('all')))));
      verifyNoBatches(a());
    });

    test('results carry timing and the detected language', () async {
      configure();
      stubMozhiEngines(a());
      final entries = await repository.compare([
        googleEngine,
        deeplEngine,
      ], autoToGerman).toList();
      final byId = {for (final e in entries) e.id: e.result!};
      expect(byId['mozhi:google']!.detectedSource, 'he');
      expect(byId['mozhi:deepl']!.detectedSource, 'he');
      expect(byId.values.map((r) => r.elapsed), everyElement(isNotNull));
    });

    test('reports each failing engine with its own error', () async {
      configure();
      whenTranslate(a()).thenAnswer((invocation) async {
        final engine = invocation.namedArguments[#engine] as String;
        if (engine == 'deepl') {
          throw const MozhiApiException(
            'Target language code invalid',
            statusCode: 500,
          );
        }
        return mozhiResult(engine, 'Hallo');
      });
      stubStream(llmOf(claudeConfig), ['Hallo']);
      final entries = await repository.compare([
        googleEngine,
        deeplEngine,
        claude,
      ], englishToGerman).toList();
      final byId = {for (final e in entries) e.id: e};
      expect(byId['mozhi:google']!.isSuccess, isTrue);
      expect(byId['ai:claude']!.isSuccess, isTrue);
      expect(byId['mozhi:deepl']!.isSuccess, isFalse);
      expect(byId['mozhi:deepl']!.name, 'DeepL');
      expect(
        byId['mozhi:deepl']!.error,
        isA<MozhiApiException>().having(
          (e) => e.message,
          'message',
          'Target language code invalid',
        ),
      );
      verifyZeroInteractions(b());
    });

    test('fails each engine over on its own', () async {
      configure();
      whenTranslate(a()).thenAnswer((invocation) async {
        final engine = invocation.namedArguments[#engine] as String;
        if (engine == 'deepl') throw serverError();
        return mozhiResult(engine, 'Hallo (A)');
      });
      whenTranslate(b()).thenAnswer((invocation) async {
        final engine = invocation.namedArguments[#engine] as String;
        return mozhiResult(engine, 'Hallo (B)');
      });
      final entries = await repository.compare([
        googleEngine,
        deeplEngine,
      ], englishToGerman).toList();
      final byId = {for (final e in entries) e.id: e.result!};
      expect(byId['mozhi:google']!.text, 'Hallo (A)');
      expect(byId['mozhi:deepl']!.text, 'Hallo (B)');
    });

    test('includes offline and machine translation engines', () async {
      final offline = FakeOfflineTranslator();
      repository = newRepository(offline: offline);
      configure(providers: [deeplConfig]);
      when(
        () => deepl.languages(type: any(named: 'type')),
      ).thenAnswer((_) async => const []);
      when(
        () => deepl.translateText(
          text: any(named: 'text'),
          targetLang: any(named: 'targetLang'),
          sourceLang: any(named: 'sourceLang'),
          formality: any(named: 'formality'),
          context: any(named: 'context'),
          preserveFormatting: any(named: 'preserveFormatting'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      ).thenAnswer(
        (_) async => const DeeplTranslation(
          text: 'Hallo Welt',
          detectedSourceLanguage: 'EN',
        ),
      );
      final entries = await repository.compare([
        TranslationEngine.offline(),
        mtEngine(deeplConfig),
      ], englishToGerman).toList();
      final byId = {for (final e in entries) e.id: e.result!};
      expect(byId['offline:mlkit']!.text, 'Hello world (en>de)');
      expect(byId['mt:deepl']!.text, 'Hallo Welt');
    });

    test('translates a single Mozhi engine', () async {
      configure();
      whenTranslate(a())
          .thenAnswer((_) async => mozhiResult('google', 'Hallo'));
      final entries = await repository.compare([
        googleEngine,
      ], englishToGerman).toList();
      expect(entries.single.result!.text, 'Hallo');
      verifyNoBatches(a());
    });

    test('reports single Mozhi failures without erroring', () async {
      configure();
      whenTranslate(a()).thenThrow(badRequest());
      final entries = await repository.compare([
        googleEngine,
      ], englishToGerman).toList();
      expect(entries.single.isSuccess, isFalse);
      expect(entries.single.id, 'mozhi:google');
      expect(entries.single.name, 'Google');
    });

    test('reports AI failures without erroring the stream', () async {
      configure(providers: [claudeConfig, openAiConfig]);
      when(() => llmOf(claudeConfig).streamChat(any())).thenAnswer(
        (_) => Stream.error(const LlmApiException('quota', statusCode: 429)),
      );
      stubStream(llmOf(openAiConfig), ['Hallo']);
      final entries = await repository.compare([
        claude,
        openAi,
      ], englishToGerman).toList();
      final byId = {for (final e in entries) e.id: e};
      expect(byId['ai:claude']!.isSuccess, isFalse);
      expect(byId['ai:claude']!.error, isA<LlmApiException>());
      expect(byId['ai:openai']!.result!.text, 'Hallo');
    });

    test('reports unknown AI providers as failures', () async {
      configure();
      final entries = await repository.compare([
        openAi,
      ], englishToGerman).toList();
      expect(entries.single.isSuccess, isFalse);
      expect(entries.single.error, isArgumentError);
    });

    test('reports custom targets on Mozhi engines as failures', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Arr']);
      final request = englishToGerman.copyWith(
        target: const Language.custom('Pirate speak'),
      );
      final entries = await repository.compare([
        googleEngine,
        deeplEngine,
        claude,
      ], request).toList();
      final byId = {for (final e in entries) e.id: e};
      expect(byId['mozhi:google']!.error, isArgumentError);
      expect(byId['mozhi:deepl']!.error, isArgumentError);
      expect(byId['ai:claude']!.result!.text, 'Arr');
      verifyZeroInteractions(a());
    });

    test('emits each entry as soon as it finishes', () async {
      configure();
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => deltas.stream);
      whenTranslate(a())
          .thenAnswer((_) async => mozhiResult('google', 'Hallo'));
      final entries = <CompareEntry>[];
      final done = Completer<void>();
      repository
          .compare([claude, googleEngine], englishToGerman)
          .listen(entries.add, onDone: done.complete);
      await pumpEventQueue();
      expect(entries.map((e) => e.id), ['mozhi:google']);
      deltas.controller.add('Hallo');
      await pumpEventQueue();
      expect(entries, hasLength(1), reason: 'only final results');
      await deltas.controller.close();
      await done.future;
      expect(entries.map((e) => e.id), ['mozhi:google', 'ai:claude']);
    });

    test('cancelling cancels running AI requests', () async {
      configure();
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => deltas.stream);
      final subscription = repository
          .compare([claude], englishToGerman)
          .listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();
      expect(deltas.cancelled, isTrue);
    });

    test('runs each engine once', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Hallo']);
      final entries = await repository.compare([
        claude,
        claude,
      ], englishToGerman).toList();
      expect(entries, hasLength(1));
      verify(() => llmOf(claudeConfig).streamChat(any())).called(1);
    });

    test('emits nothing for empty input or no engines', () async {
      configure();
      expect(
        await repository.compare([
          googleEngine,
          claude,
        ], englishToGerman.copyWith(text: '')).toList(),
        isEmpty,
      );
      expect(await repository.compare([], englishToGerman).toList(), isEmpty);
      expect(mozhiBuilt, isEmpty);
      expect(llmBuilt, isEmpty);
    });
  });

  // JSON features

  group('JSON features', () {
    final alternativesJson = jsonEncode({
      'description': 'Neutral greeting.',
      'alternatives': [
        {'text': 'Servus Welt', 'explanation': 'Austrian'},
        {'text': 'Grüß dich, Welt', 'explanation': 'Southern'},
      ],
    });

    test('getAlternatives sends a JSON request and parses it', () async {
      configure();
      stubChat(llmOf(claudeConfig), [alternativesJson]);
      final result = await repository.getAlternatives(
        claude,
        englishToGerman,
        'Hallo Welt',
        count: 2,
        span: 'Hallo',
        uiLanguage: 'German',
      );
      expect(result.description, 'Neutral greeting.');
      expect(result.alternatives.map((a) => a.text), [
        'Servus Welt',
        'Grüß dich, Welt',
      ]);
      final request = capturedChats(llmOf(claudeConfig)).single;
      expect(request.jsonOutput, isTrue);
      expect(request.temperature, isNull);
      expect(request.effort, 'low');
      expect(request.model, 'claude-opus-5-5');
      expect(
        request.messages,
        TranslationPrompts.alternatives(
          englishToGerman,
          'Hallo Welt',
          count: 2,
          span: 'Hallo',
          uiLanguage: 'German',
        ),
      );
    });

    test('retries once with a request for valid JSON', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['Sure! Here you go.', alternativesJson]);
      final result = await repository.getAlternatives(
        claude,
        englishToGerman,
        'Hallo Welt',
      );
      expect(result.alternatives, hasLength(2));
      final requests = capturedChats(llmOf(claudeConfig));
      expect(requests, hasLength(2));
      final original = requests.first.messages;
      final retry = requests.last.messages;
      expect(retry.sublist(0, original.length), original);
      expect(retry, hasLength(original.length + 2));
      expect(retry[original.length].role, LlmRole.assistant);
      expect(retry[original.length].content, 'Sure! Here you go.');
      expect(retry.last.role, LlmRole.user);
      expect(retry.last.content, contains('JSON'));
      expect(requests.last.jsonOutput, isTrue);
    });

    test('does not echo an empty reply when retrying', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['  ', alternativesJson]);
      await repository.getAlternatives(claude, englishToGerman, 'Hallo Welt');
      final requests = capturedChats(llmOf(claudeConfig));
      expect(
        requests.last.messages,
        hasLength(requests.first.messages.length + 1),
      );
      expect(requests.last.messages.last.role, LlmRole.user);
    });

    test('throws the FormatException when the retry is invalid too', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['nope', 'still nope']);
      await expectLater(
        repository.getAlternatives(claude, englishToGerman, 'Hallo Welt'),
        throwsFormatException,
      );
      verify(() => llmOf(claudeConfig).chat(any())).called(2);
    });

    test('does not retry provider errors', () async {
      configure();
      when(() => llmOf(claudeConfig).chat(any()))
          .thenThrow(const LlmApiException('unauthorized', statusCode: 401));
      await expectLater(
        repository.getSuggestions(claude, englishToGerman, 'Hallo Welt'),
        throwsA(isA<LlmApiException>()),
      );
      verify(() => llmOf(claudeConfig).chat(any())).called(1);
    });

    test('sends the temperature to non-Anthropic providers', () async {
      configure(providers: [openAiConfig]);
      stubChat(llmOf(openAiConfig), [alternativesJson]);
      await repository.getAlternatives(openAi, englishToGerman, 'Hallo Welt');
      final request = capturedChats(llmOf(openAiConfig)).single;
      expect(request.temperature, 0.3);
      expect(request.jsonOutput, isTrue);
    });

    test('require an AI engine', () async {
      configure();
      await expectLater(
        repository.getAlternatives(googleEngine, englishToGerman, 'x'),
        throwsArgumentError,
      );
      await expectLater(
        repository.getInsights(googleEngine, englishToGerman, 'x'),
        throwsArgumentError,
      );
      await expectLater(
        repository.getSuggestions(googleEngine, englishToGerman, 'x'),
        throwsArgumentError,
      );
      await expectLater(
        repository.lookUp(googleEngine, 'x', source: english, target: german),
        throwsArgumentError,
      );
      await expectLater(
        repository.proofread(googleEngine, 'x'),
        throwsArgumentError,
      );
      await expectLater(
        repository.getAlternatives(openAi, englishToGerman, 'x'),
        throwsArgumentError,
        reason: 'unknown provider',
      );
      expect(llmBuilt, isEmpty);
      expect(mozhiBuilt, isEmpty);
    });

    test('getInsights keeps insights that match the translation', () async {
      configure();
      stubChat(llmOf(claudeConfig), [
        jsonEncode({
          'insights': [
            {
              'source': 'Hello',
              'target': 'Hallo',
              'type': 'nuance',
              'explanation': 'Neutral',
              'variations': [
                {'text': 'Servus', 'explanation': 'Casual'},
              ],
            },
            {
              'source': 'world',
              'target': 'Erde',
              'type': 'nuance',
              'explanation': 'x',
              'variations': <Object>[],
            },
          ],
        }),
      ]);
      final insights = await repository.getInsights(
        claude,
        englishToGerman,
        'Hallo Welt',
        uiLanguage: 'French',
      );
      expect(insights.single.targetText, 'Hallo');
      expect(insights.single.sourceText, 'Hello');
      expect(insights.single.variations.single.text, 'Servus');
      expect(
        capturedChats(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.insights(
          englishToGerman,
          'Hallo Welt',
          uiLanguage: 'French',
        ),
      );
    });

    test('getSuggestions parses refinement chips', () async {
      configure();
      stubChat(llmOf(claudeConfig), [
        jsonEncode({
          'suggestions': [
            {
              'label': 'More formal',
              'description': 'Sie',
              'instruction': 'Use the formal Sie.',
              'icon': 'formal',
            },
          ],
        }),
      ]);
      final suggestions = await repository.getSuggestions(
        claude,
        englishToGerman,
        'Hallo Welt',
      );
      expect(suggestions.single.label, 'More formal');
      expect(suggestions.single.instruction, 'Use the formal Sie.');
      expect(
        capturedChats(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.suggestions(englishToGerman, 'Hallo Welt'),
      );
    });

    test('lookUp parses a dictionary entry', () async {
      configure();
      stubChat(llmOf(claudeConfig), [
        jsonEncode({
          'word': 'Haus',
          'pronunciation': 'haʊs',
          'parts_of_speech': ['noun'],
          'senses': [
            {
              'part_of_speech': 'noun',
              'definition': 'house',
              'translations': ['house'],
              'usage': '',
            },
          ],
          'examples': [
            {'source': 'Das Haus', 'translation': 'The house'},
          ],
          'synonyms': ['Gebäude'],
          'etymology': 'Old High German hūs',
          'notes': '',
        }),
      ]);
      final entry = await repository.lookUp(
        claude,
        'Haus',
        source: german,
        target: english,
        context: 'Das Haus ist groß.',
      );
      expect(entry.word, 'Haus');
      expect(entry.senses.single.definition, 'house');
      expect(entry.synonyms, ['Gebäude']);
      expect(
        capturedChats(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.dictionary(
          'Haus',
          source: german,
          targetLanguage: english,
          context: 'Das Haus ist groß.',
        ),
      );
    });

    test('proofread keeps edits that occur in the input', () async {
      configure();
      stubChat(llmOf(claudeConfig), [
        jsonEncode({
          'language': 'en',
          'corrected': 'I have a cat.',
          'summary': 'Fine.',
          'edits': [
            {
              'original': 'has',
              'replacement': 'have',
              'explanation': 'Agreement',
              'category': 'grammar',
            },
            {
              'original': 'missing',
              'replacement': 'x',
              'explanation': '',
              'category': 'style',
            },
          ],
        }),
      ]);
      final result = await repository.proofread(
        claude,
        'I has a cat.',
        style: WritingStyle.casual,
        level: CorrectionLevel.light,
        formality: Formality.less,
        context: 'chat',
      );
      expect(result.correctedText, 'I have a cat.');
      expect(result.edits.single.original, 'has');
      expect(
        capturedChats(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.proofread(
          'I has a cat.',
          style: WritingStyle.casual,
          level: CorrectionLevel.light,
          formality: Formality.less,
          context: 'chat',
        ),
      );
    });
  });

  // detectLanguage

  group('detectLanguage', () {
    test('uses the AI engine when given', () async {
      configure();
      stubChat(llmOf(claudeConfig), [
        jsonEncode({
          'language': 'ja',
          'uncertain': false,
          'mixed': true,
          'alternatives': ['zh'],
        }),
      ]);
      final detected = await repository.detectLanguage('こんにちは', engine: claude);
      expect(detected.code, 'ja');
      expect(detected.isMixed, isTrue);
      final request = capturedChats(llmOf(claudeConfig)).single;
      expect(request.jsonOutput, isTrue);
      expect(request.messages, TranslationPrompts.detectLanguage('こんにちは'));
      expect(mozhiBuilt, isEmpty);
    });

    test('falls back to Mozhi google with from=auto', () async {
      configure();
      whenTranslate(a()).thenAnswer(
        (_) async => const MozhiTranslation(
          engine: 'google',
          translatedText: 'Hello',
          detectedLanguage: 'iw',
        ),
      );
      final detected = await repository.detectLanguage('שלום');
      expect(detected.code, 'he');
      verify(
        () => a().translate(
          engine: 'google',
          from: 'auto',
          to: any(named: 'to'),
          text: 'שלום',
        ),
      ).called(1);
    });

    test('uses Mozhi google for Mozhi engines', () async {
      configure();
      whenTranslate(a()).thenAnswer(
        (_) async => const MozhiTranslation(
          engine: 'google',
          translatedText: 'Hello',
          detectedLanguage: 'fr',
        ),
      );
      final detected = await repository.detectLanguage(
        'Bonjour',
        engine: deeplEngine,
      );
      expect(detected.code, 'fr');
      verify(
        () => a().translate(
          engine: 'google',
          from: 'auto',
          to: any(named: 'to'),
          text: 'Bonjour',
        ),
      ).called(1);
    });

    test('fails over between instances', () async {
      configure();
      whenTranslate(a()).thenThrow(serverError());
      whenTranslate(b()).thenAnswer(
        (_) async => const MozhiTranslation(
          engine: 'google',
          translatedText: 'Hello',
          detectedLanguage: 'de',
        ),
      );
      expect((await repository.detectLanguage('Hallo')).code, 'de');
    });

    test('throws when Mozhi reports no language', () async {
      configure();
      whenTranslate(a()).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'google', translatedText: 'x'),
      );
      await expectLater(
        repository.detectLanguage('???'),
        throwsA(isA<MozhiApiException>()),
      );
    });

    test('throws when nothing can detect', () async {
      configure(instances: []);
      await expectLater(repository.detectLanguage('Hallo'), throwsStateError);
    });
  });

  // explain

  group('explain', () {
    test('streams Markdown deltas from the explain prompt', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['# Why', '\n', 'Because.']);
      final chunks = await repository
          .explain(
            claude,
            englishToGerman,
            'Hallo Welt',
            question: 'Why Hallo?',
            uiLanguage: 'Spanish',
          )
          .toList();
      expect(chunks.join(), '# Why\nBecause.');
      final request = capturedStream(llmOf(claudeConfig));
      expect(
        request.messages,
        TranslationPrompts.explain(
          englishToGerman,
          'Hallo Welt',
          question: 'Why Hallo?',
          uiLanguage: 'Spanish',
        ),
      );
      expect(request.temperature, isNull);
      expect(request.jsonOutput, isFalse);
    });

    test('rejects unknown providers', () async {
      configure();
      await expectLater(
        repository.explain(openAi, englishToGerman, 'Hallo Welt'),
        emitsError(isArgumentError),
      );
      expect(llmBuilt, isEmpty);
    });

    test('requires an AI engine', () async {
      configure();
      await expectLater(
        repository.explain(googleEngine, englishToGerman, 'Hallo Welt'),
        emitsError(isArgumentError),
      );
    });

    test('cancelling cancels the provider stream', () async {
      configure();
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => deltas.stream);
      final subscription = repository
          .explain(claude, englishToGerman, 'Hallo Welt')
          .listen((_) {});
      await pumpEventQueue();
      deltas.controller.add('# A');
      await pumpEventQueue();
      await subscription.cancel();
      expect(deltas.cancelled, isTrue);
    });
  });

  // textToSpeech

  group('textToSpeech', () {
    final googleAudio = Uint8List.fromList([1, 2, 3]);
    final reversoAudio = Uint8List.fromList([4, 5, 6]);

    test('uses google on the active instance', () async {
      configure();
      whenTts(a(), 'google').thenAnswer((_) async => googleAudio);
      final audio = await repository.textToSpeech(
        text: 'Hallo',
        languageCode: 'de',
      );
      expect(audio, googleAudio);
      verify(
        () => a().textToSpeech(engine: 'google', language: 'de', text: 'Hallo'),
      ).called(1);
    });

    test('fails over between instances', () async {
      configure();
      whenTts(a(), 'google').thenThrow(serverError());
      whenTts(b(), 'google').thenAnswer((_) async => googleAudio);
      expect(
        await repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        googleAudio,
      );
      expect(repository.activeInstance, instanceB);
    });

    test('falls back to reverso when google fails', () async {
      configure();
      whenTts(a(), 'google').thenThrow(serverError());
      whenTts(b(), 'google').thenThrow(serverError());
      whenTts(a(), 'reverso').thenAnswer((_) async => reversoAudio);
      expect(
        await repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        reversoAudio,
      );
    });

    test('falls back to reverso on non-retryable google errors', () async {
      configure();
      whenTts(a(), 'google').thenThrow(badRequest('unsupported language'));
      whenTts(a(), 'reverso').thenAnswer((_) async => reversoAudio);
      expect(
        await repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        reversoAudio,
      );
    });

    test('rethrows the google error when reverso fails too', () async {
      configure(instances: [instanceA]);
      whenTts(a(), 'google').thenThrow(serverError('google down'));
      whenTts(a(), 'reverso').thenThrow(serverError('reverso down'));
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(
          isA<MozhiApiException>().having(
            (e) => e.message,
            'message',
            'google down',
          ),
        ),
      );
    });

    test('does not fall back when reverso was requested', () async {
      configure(instances: [instanceA]);
      whenTts(a(), 'reverso').thenThrow(serverError());
      await expectLater(
        repository.textToSpeech(
          text: 'Hallo',
          languageCode: 'de',
          engine: 'reverso',
        ),
        throwsA(isA<MozhiApiException>()),
      );
      verifyNever(
        () => a().textToSpeech(
          engine: 'google',
          language: any(named: 'language'),
          text: any(named: 'text'),
        ),
      );
    });

    test('throws when no instance is configured', () async {
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(isA<MozhiApiException>()),
      );
    });
  });

  // translateImage

  group('translateImage', () {
    final image = Uint8List.fromList([137, 80, 78, 71]);
    final translatedImage = [9, 8, 7];

    test('AI engines use the vision prompt', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['[[lang:ja]]\n# Menu\n- Ramen']);
      final result = await repository.translateImage(
        claude,
        image,
        mimeType: 'image/jpeg',
        source: Language.auto,
        target: english,
      );
      expect(result.translatedText, '# Menu\n- Ramen');
      expect(result.translatedImage, isNull);
      final request = capturedChats(llmOf(claudeConfig)).single;
      final expected = TranslationPrompts.translateImage(
        image,
        mimeType: 'image/jpeg',
        source: Language.auto,
        target: english,
      );
      expect(request.messages, expected);
      expect(
        request.messages.expand((m) => m.images).single.mimeType,
        'image/jpeg',
      );
      expect(request.temperature, isNull);
    });

    test('AI engines receive the translation options', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['Menu']);
      const options = TranslationOptions(
        formality: Formality.more,
        context: 'restaurant menu',
      );
      final result = await repository.translateImage(
        claude,
        image,
        mimeType: 'image/png',
        source: german,
        target: english,
        options: options,
      );
      expect(result.translatedText, 'Menu');
      expect(
        capturedChats(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.translateImage(
          image,
          mimeType: 'image/png',
          source: german,
          target: english,
          options: options,
        ),
      );
    });

    test('AI engines must be configured', () async {
      configure();
      await expectLater(
        repository.translateImage(
          openAi,
          image,
          mimeType: 'image/png',
          source: Language.auto,
          target: english,
        ),
        throwsArgumentError,
      );
    });

    test('Mozhi engines use /api/image with google', () async {
      configure();
      when(
        () => a().translateImage(
          pngBytes: any(named: 'pngBytes'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          engine: any(named: 'engine'),
        ),
      ).thenAnswer(
        (_) async => MozhiImageTranslation(
          translatedImageBase64: base64.encode(translatedImage),
          sourceText: 'こんにちは',
          translatedText: 'Hello',
        ),
      );
      final result = await repository.translateImage(
        deeplEngine,
        image,
        mimeType: 'image/png',
        source: Language.auto,
        target: english,
      );
      expect(result.translatedImage, translatedImage);
      expect(result.sourceText, 'こんにちは');
      expect(result.translatedText, 'Hello');
      verify(() => a().translateImage(pngBytes: image, from: 'auto', to: 'en'))
          .called(1);
    });

    test('Mozhi image translation fails over', () async {
      configure();
      when(
        () => a().translateImage(
          pngBytes: any(named: 'pngBytes'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          engine: any(named: 'engine'),
        ),
      ).thenThrow(serverError());
      when(
        () => b().translateImage(
          pngBytes: any(named: 'pngBytes'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          engine: any(named: 'engine'),
        ),
      ).thenAnswer(
        (_) async => const MozhiImageTranslation(translatedImageBase64: ''),
      );
      final result = await repository.translateImage(
        googleEngine,
        image,
        mimeType: 'image/png',
        source: Language.auto,
        target: english,
      );
      expect(result.translatedImage, isNull);
      expect(repository.activeInstance, instanceB);
    });

    test('Mozhi engines require PNG and real languages', () async {
      configure();
      await expectLater(
        repository.translateImage(
          googleEngine,
          image,
          mimeType: 'image/jpeg',
          source: Language.auto,
          target: english,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repository.translateImage(
          googleEngine,
          image,
          mimeType: 'image/png',
          source: Language.auto,
          target: const Language.custom('Pirate speak'),
        ),
        throwsArgumentError,
      );
      expect(mozhiBuilt, isEmpty);
    });
  });

  // instances & providers

  group('pingInstance', () {
    test('uses the cached client of a configured instance', () async {
      configure();
      when(a().ping).thenAnswer((_) async => const Duration(milliseconds: 42));
      stubEngines(a(), {'google': 'Google'});
      await repository.getEngines();
      expect(
        await repository.pingInstance(instanceA),
        const Duration(milliseconds: 42),
      );
      expect(mozhiBuilt, hasLength(1));
      verifyNever(a().close);
    });

    test('uses a temporary client for other instances', () async {
      configure(instances: [instanceA]);
      when(c().ping).thenAnswer((_) async => const Duration(seconds: 1));
      expect(
        await repository.pingInstance(instanceC),
        const Duration(seconds: 1),
      );
      verify(c().close).called(1);
    });

    test('throws on failure', () async {
      when(c().ping).thenThrow(serverError());
      await expectLater(
        repository.pingInstance(instanceC),
        throwsA(isA<MozhiApiException>()),
      );
      verify(c().close).called(1);
    });
  });

  group('listModels', () {
    test('uses a temporary client', () async {
      configure(providers: [claudeConfig]);
      stubStream(llmOf(claudeConfig), ['Hallo']);
      await repository.translate(claude, englishToGerman).drain<void>();

      final temporary = MockLlmClient();
      llmQueue.add(temporary);
      when(
        temporary.listModels,
      ).thenAnswer((_) async => const [LlmModel(id: 'a'), LlmModel(id: 'b')]);
      final models = await repository.listModels(claudeConfig);
      expect(models.map((m) => m.id), ['a', 'b']);
      verify(temporary.close).called(1);
      verifyNever(llmOf(claudeConfig).close);
      expect(llmBuilt, hasLength(2));
    });

    test('closes the client on failure', () async {
      when(llmOf(openAiConfig).listModels)
          .thenThrow(const LlmApiException('no listing'));
      await expectLater(
        repository.listModels(openAiConfig),
        throwsA(isA<LlmApiException>()),
      );
      verify(llmOf(openAiConfig).close).called(1);
    });
  });

  group('testProvider', () {
    const hello = TranslationRequest(
      text: 'Hello, world!',
      source: english,
      target: french,
    );

    test('translates a sample sentence to French', () async {
      stubChat(llmOf(claudeConfig), ['"Bonjour, le monde !"']);
      final output = await repository.testProvider(claudeConfig);
      expect(output, 'Bonjour, le monde !');
      final request = capturedChats(llmOf(claudeConfig)).single;
      expect(request.messages, TranslationPrompts.translate(hello));
      expect(request.model, 'claude-opus-5-5');
      expect(request.temperature, isNull);
      verify(llmOf(claudeConfig).close).called(1);
    });

    test('works for providers that are not configured yet', () async {
      configure(providers: []);
      stubChat(llmOf(openAiConfig), ['Bonjour le monde']);
      expect(await repository.testProvider(openAiConfig), 'Bonjour le monde');
      expect(capturedChats(llmOf(openAiConfig)).single.temperature, 0.3);
    });

    test('throws on an empty answer', () async {
      stubChat(llmOf(claudeConfig), ['   ']);
      await expectLater(
        repository.testProvider(claudeConfig),
        throwsA(isA<LlmApiException>()),
      );
      verify(llmOf(claudeConfig).close).called(1);
    });

    test('throws the provider error', () async {
      when(() => llmOf(claudeConfig).chat(any()))
          .thenThrow(const LlmApiException('bad key', statusCode: 401));
      await expectLater(
        repository.testProvider(claudeConfig),
        throwsA(
          isA<LlmApiException>().having((e) => e.isAuthError, 'auth', isTrue),
        ),
      );
      verify(llmOf(claudeConfig).close).called(1);
    });
  });
}
