import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  const lanInstance = MozhiInstance(url: 'http://192.168.1.10:3000');
  const onionInstance = MozhiInstance(url: 'http://mozhiabcdef.onion');
  const publicLibreConfig = AiProviderConfig(
    id: 'libre-public',
    name: 'LibreTranslate',
    provider: LlmProvider.openAiCompatible,
    baseUrl: 'https://libretranslate.com',
    model: '',
    service: MtService.libreTranslate,
  );
  const deeplProxyConfig = AiProviderConfig(
    id: 'deepl-proxy',
    name: 'DeepL via proxy',
    provider: LlmProvider.openAiCompatible,
    baseUrl: 'http://10.0.0.2:1188',
    model: '',
    apiKey: 'pro-key',
    service: MtService.deepl,
  );
  const visionClaude = AiProviderConfig(
    id: 'claude',
    name: 'Claude',
    provider: LlmProvider.anthropic,
    baseUrl: 'https://api.anthropic.com/v1',
    model: 'claude-opus-5-5',
    supportsVision: true,
  );

  late Map<String, MockMozhiApiClient> mozhi;
  late Map<String, MockLlmClient> llm;
  late MockDeeplClient deepl;
  late MockLibreTranslateClient libre;
  late FakeOfflineTranslator offline;
  late List<String> clientsBuilt;
  late DateTime now;
  late TranslationRepository repository;

  MockMozhiApiClient a() => mozhi[instanceA.url]!;
  MockMozhiApiClient b() => mozhi[instanceB.url]!;
  MockMozhiApiClient lan() => mozhi[lanInstance.url]!;
  MockLlmClient claudeClient() => llm['api.anthropic.com']!;
  MockLlmClient ollamaClient() => llm['localhost']!;

  TranslationRepository newRepository({
    OfflineTranslator? offlineTranslator,
    MetadataStore? store,
  }) => TranslationRepository(
    mozhiClientFactory: (uri) {
      clientsBuilt.add('mozhi ${uri.host}');
      return mozhi[uri.toString()]!;
    },
    llmClientFactory: (endpoint) {
      clientsBuilt.add('llm ${endpoint.baseUrl.host}');
      return llm[endpoint.baseUrl.host]!;
    },
    deeplClientFactory: (config) {
      clientsBuilt.add('deepl');
      return deepl;
    },
    libreTranslateClientFactory: (config) {
      clientsBuilt.add('libre');
      return libre;
    },
    offline: offlineTranslator,
    metadataStore: store,
    clock: () => now,
    snapshotInterval: Duration.zero,
  );

  void configure({
    List<MozhiInstance> instances = const [instanceA, instanceB],
    List<AiProviderConfig> providers = const [
      claudeConfig,
      ollamaConfig,
      deeplConfig,
      libreConfig,
      cloudGemmaConfig,
    ],
  }) => repository.updateConfiguration(
    instances: instances,
    providers: providers,
  );

  setUp(() {
    mozhi = {
      for (final instance in [instanceA, instanceB, lanInstance, onionInstance])
        instance.url: MockMozhiApiClient(),
    };
    llm = {
      for (final host in [
        'api.anthropic.com',
        'localhost',
        'mt.example.com',
        'api.openai.com',
      ])
        host: MockLlmClient(),
    };
    deepl = MockDeeplClient();
    libre = MockLibreTranslateClient();
    offline = FakeOfflineTranslator();
    clientsBuilt = [];
    now = DateTime.utc(2026, 10, 17, 12);
    repository = newRepository(offlineTranslator: offline);
    configure();
  });

  tearDown(() => repository.dispose());

  // stubs

  When<Future<MozhiTranslation>> whenTranslate(MockMozhiApiClient client) =>
      when(
        () => client.translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      );

  void stubMozhi(MockMozhiApiClient client, [String text = 'Hallo']) =>
      whenTranslate(client).thenAnswer(
        (_) async => MozhiTranslation(
          engine: 'google',
          translatedText: text,
          detectedLanguage: 'en',
        ),
      );

  void stubStream(MockLlmClient client, List<String> deltas) =>
      when(() => client.streamChat(any()))
          .thenAnswer((_) => Stream.fromIterable(deltas));

  void stubChat(MockLlmClient client, String output) =>
      when(() => client.chat(any())).thenAnswer((_) async => output);

  void stubDeepl() =>
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
        (_) async =>
            const DeeplTranslation(text: 'Hallo', detectedSourceLanguage: 'EN'),
      );

  void stubDeeplLanguages() =>
      when(() => deepl.languages(type: any(named: 'type'))).thenAnswer(
        (_) async => const [
          DeeplLanguage(code: 'EN', name: 'English'),
          DeeplLanguage(code: 'DE', name: 'German'),
        ],
      );

  void stubLibre() {
    when(libre.languages).thenAnswer((_) async => const []);
    when(
      () => libre.translate(
        text: any(named: 'text'),
        target: any(named: 'target'),
        source: any(named: 'source'),
        abortTrigger: any(named: 'abortTrigger'),
      ),
    ).thenAnswer((_) async => const LibreTranslation(text: 'Hallo'));
  }

  const englishToGerman = TranslationRequest(
    text: 'Hello world',
    source: english,
    target: german,
  );
  const autoToGerman = TranslationRequest(
    text: 'Hello world',
    source: Language.auto,
    target: german,
  );
  final claude = aiEngine(claudeConfig);
  final ollama = aiEngine(ollamaConfig);
  final cloudGemma = aiEngine(cloudGemmaConfig);
  final deeplMt = mtEngine(deeplConfig);
  final libreMt = mtEngine(libreConfig);
  final offlineEngine = TranslationEngine.offline();

  Future<TranslationResult> finalResult(
    TranslationEngine engine,
    TranslationRequest request,
  ) => repository
      .translate(engine, request)
      .lastWhere((result) => result.isComplete);

  TypeMatcher<ConsentRequiredException> consent(
    ConsentKind kind, {
    String? engineId,
    DataDestination? destination,
    String? source,
    String? target,
  }) => isA<ConsentRequiredException>()
      .having((e) => e.kind, 'kind', kind)
      .having((e) => e.engineId, 'engineId', engineId ?? anything)
      .having((e) => e.destination, 'destination', destination ?? anything)
      .having((e) => e.source, 'source', source ?? anything)
      .having((e) => e.target, 'target', target ?? anything);

  void expectNoNetwork() {
    expect(clientsBuilt, isEmpty);
    verifyZeroInteractions(a());
    verifyZeroInteractions(b());
    verifyZeroInteractions(claudeClient());
    verifyZeroInteractions(ollamaClient());
    verifyZeroInteractions(deepl);
    verifyZeroInteractions(libre);
  }

  test('cancelling a Mozhi translation aborts its request', () async {
    repository.updatePrivacy(mode: PrivacyMode.online);
    Future<void>? abort;
    final pending = Completer<MozhiTranslation>();
    whenTranslate(a()).thenAnswer((invocation) {
      abort = invocation.namedArguments[#abortTrigger] as Future<void>?;
      return pending.future;
    });
    final subscription = repository
        .translate(googleEngine, englishToGerman)
        .listen((_) {});
    await pumpEventQueue();
    var aborted = false;
    unawaited(abort!.then((_) => aborted = true));
    await subscription.cancel();
    await pumpEventQueue();
    expect(aborted, isTrue);
    pending.completeError(const MozhiRequestCancelledException());
    await pumpEventQueue();
    verifyZeroInteractions(b());
  });

  group('pairKey and providerIdOf', () {
    test('pairKey joins the codes', () {
      expect(TranslationRepository.pairKey('de', 'en'), 'de>en');
      expect(TranslationRepository.pairKey('auto', 'fr'), 'auto>fr');
    });

    test('providerIdOf strips the ai: and mt: prefixes', () {
      expect(TranslationRepository.providerIdOf('ai:claude'), 'claude');
      expect(TranslationRepository.providerIdOf('mt:deepl'), 'deepl');
      expect(TranslationRepository.providerIdOf('mozhi:google'), isNull);
      expect(TranslationRepository.providerIdOf('ai:'), isNull);
      expect(TranslationRepository.providerIdOf('offline:mlkit'), isNull);
    });
  });

  test('results compare their destinations', () {
    const result = TranslationResult(engineId: 'e', engineName: 'E', text: 't');
    final sent = result.copyWith(destination: const OnDeviceDestination());
    expect(sent, isNot(result));
    expect(sent, result.copyWith(destination: const OnDeviceDestination()));
    expect(sent.toString(), contains('OnDeviceDestination'));
    const image = ImageTranslationResult(translatedText: 't');
    const sentImage = ImageTranslationResult(
      translatedText: 't',
      destination: OnDeviceDestination(),
    );
    expect(sentImage, isNot(image));
    expect(sentImage.hashCode, isNot(image.hashCode));
  });

  group('updatePrivacy', () {
    test('starts strict: offline first, nothing approved', () {
      expect(repository.privacyMode, PrivacyMode.offlineFirst);
      expect(repository.approvedPairs, isEmpty);
      expect(repository.consentedProviders, isEmpty);
    });

    test('exposes the pushed settings', () {
      repository.updatePrivacy(
        mode: PrivacyMode.online,
        approvedPairs: ['de>en', 'de>en'],
        consentedProviders: ['claude'],
      );
      expect(repository.privacyMode, PrivacyMode.online);
      expect(repository.approvedPairs, {'de>en'});
      expect(repository.consentedProviders, {'claude'});
      expect(() => repository.approvedPairs.add('x'), throwsUnsupportedError);
    });
  });

  group('destinationOf', () {
    test('the offline engine stays on the device', () {
      expect(
        repository.destinationOf(TranslationEngine.offlineId),
        const OnDeviceDestination(),
      );
    });

    test('Mozhi engines go to the active public instance and upstream', () {
      expect(
        repository.destinationOf('mozhi:google'),
        const PublicInstanceDestination('a.example', engine: 'google'),
      );
    });

    test('Mozhi on a private network or Tor is self-hosted', () {
      configure(instances: [lanInstance]);
      expect(
        repository.destinationOf('mozhi:deepl'),
        const SelfHostedDestination('192.168.1.10'),
      );
      configure(instances: [onionInstance]);
      expect(
        repository.destinationOf('mozhi:google'),
        const SelfHostedDestination('mozhiabcdef.onion'),
      );
    });

    test('Mozhi without instances is an unnamed public destination', () {
      configure(instances: []);
      expect(
        repository.destinationOf('mozhi:google'),
        const PublicInstanceDestination('', engine: 'google'),
      );
    });

    test('cloud AI providers are named after the provider', () {
      expect(
        repository.destinationOf('ai:claude'),
        const CloudProviderDestination('Claude', host: 'api.anthropic.com'),
      );
    });

    test('a nameless cloud AI provider is named after its host', () {
      configure(providers: [claudeConfig.copyWith(name: ' ')]);
      expect(
        repository.destinationOf('ai:claude'),
        const CloudProviderDestination(
          'api.anthropic.com',
          host: 'api.anthropic.com',
        ),
      );
    });

    test('local AI providers are self-hosted', () {
      expect(
        repository.destinationOf('ai:ollama'),
        const SelfHostedDestination('localhost'),
      );
    });

    test('DeepL is always the DeepL cloud', () {
      expect(
        repository.destinationOf('mt:deepl'),
        const CloudProviderDestination('DeepL', host: 'api-free.deepl.com'),
      );
      configure(providers: [deeplProxyConfig]);
      expect(
        repository.destinationOf('mt:deepl-proxy'),
        const CloudProviderDestination('DeepL', host: '10.0.0.2'),
      );
      configure(providers: [deeplConfig.copyWith(apiKey: 'pro')]);
      expect(
        repository.destinationOf('mt:deepl'),
        const CloudProviderDestination('DeepL', host: 'api.deepl.com'),
      );
    });

    test('LibreTranslate is public or self-hosted by its URL', () {
      expect(
        repository.destinationOf('mt:libre'),
        const SelfHostedDestination('localhost'),
      );
      configure(
        providers: [
          publicLibreConfig,
          libreConfig.copyWith(baseUrl: ''),
        ],
      );
      expect(
        repository.destinationOf('mt:libre-public'),
        const PublicInstanceDestination('libretranslate.com'),
      );
      expect(
        repository.destinationOf('mt:libre'),
        const PublicInstanceDestination('libretranslate.com'),
      );
    });

    test('unknown providers are an ArgumentError', () {
      expect(() => repository.destinationOf('ai:nope'), throwsArgumentError);
      expect(() => repository.destinationOf('nope'), throwsArgumentError);
    });
  });

  group('result destinations', () {
    setUp(
      () => repository.updatePrivacy(
        mode: PrivacyMode.online,
        consentedProviders: testProviderIds,
      ),
    );

    test('Mozhi results name the instance that answered', () async {
      stubMozhi(a());
      expect(
        (await finalResult(googleEngine, englishToGerman)).destination,
        const PublicInstanceDestination('a.example', engine: 'google'),
      );
    });

    test('after a failover, the instance that answered', () async {
      whenTranslate(a()).thenThrow(serverError());
      stubMozhi(b());
      expect(
        (await finalResult(googleEngine, englishToGerman)).destination,
        const PublicInstanceDestination('b.example', engine: 'google'),
      );
    });

    test('cached results keep the destination they came from', () async {
      whenTranslate(a()).thenThrow(serverError());
      stubMozhi(b());
      await finalResult(googleEngine, englishToGerman);
      repository.resetActiveInstance();
      final cached = await finalResult(googleEngine, englishToGerman);
      expect(cached.fromCache, isTrue);
      expect(
        cached.destination,
        const PublicInstanceDestination('b.example', engine: 'google'),
      );
    });

    test('AI, machine translation and offline results', () async {
      stubStream(claudeClient(), ['Hallo']);
      stubStream(ollamaClient(), ['Hallo']);
      stubDeepl();
      stubDeeplLanguages();
      stubLibre();
      final results = [
        for (final engine in [claude, ollama, deeplMt, libreMt, offlineEngine])
          await repository.translate(engine, englishToGerman).toList(),
      ];
      expect(
        [
          for (final events in results)
            events.map((r) => r.destination).toSet(),
        ],
        [
          {const CloudProviderDestination('Claude', host: 'api.anthropic.com')},
          {const SelfHostedDestination('localhost')},
          {const CloudProviderDestination('DeepL', host: 'api-free.deepl.com')},
          {const SelfHostedDestination('localhost')},
          {const OnDeviceDestination()},
        ],
      );
    });

    test('refinements name the provider', () async {
      stubStream(claudeClient(), ['Guten Tag']);
      final results = await repository
          .refine(
            claude,
            englishToGerman,
            currentTranslation: 'Hallo',
            instruction: 'More formal',
          )
          .toList();
      expect(
        results.last.destination,
        const CloudProviderDestination('Claude', host: 'api.anthropic.com'),
      );
    });

    test('image results name the provider or the instance', () async {
      configure(providers: [visionClaude]);
      stubChat(claudeClient(), 'Hallo');
      final ai = await repository.translateImage(
        aiEngine(visionClaude),
        Uint8List(4),
        mimeType: 'image/jpeg',
        source: english,
        target: german,
      );
      expect(
        ai.destination,
        const CloudProviderDestination('Claude', host: 'api.anthropic.com'),
      );
      when(
        () => a().translateImage(
          pngBytes: any(named: 'pngBytes'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          timeout: any(named: 'timeout'),
        ),
      ).thenThrow(serverError());
      when(
        () => b().translateImage(
          pngBytes: any(named: 'pngBytes'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer(
        (_) async => MozhiImageTranslation(
          translatedImageBase64: base64Encode([1, 2]),
          translatedText: 'Hallo',
        ),
      );
      final image = await repository.translateImage(
        deeplEngine,
        Uint8List(4),
        mimeType: 'image/png',
        source: english,
        target: german,
      );
      expect(
        image.destination,
        const PublicInstanceDestination('b.example', engine: 'google'),
      );
    });
  });

  group('offline only', () {
    setUp(
      () => repository.updatePrivacy(
        mode: PrivacyMode.offlineOnly,
        approvedPairs: ['en>de', 'auto>de', 'auto>auto', 'de>de'],
        consentedProviders: testProviderIds,
      ),
    );

    test('translations to any network engine fail without a request', () async {
      for (final engine in [googleEngine, claude, ollama, deeplMt, libreMt]) {
        await expectLater(
          repository.translate(engine, englishToGerman),
          emitsError(
            consent(
              ConsentKind.offlineOnly,
              engineId: engine.id,
              destination: repository.destinationOf(engine.id),
              source: 'en',
              target: 'de',
            ),
          ),
        );
      }
      expectNoNetwork();
    });

    test('the offline engine still translates', () async {
      final result = await finalResult(offlineEngine, englishToGerman);
      expect(result.text, 'Hello world (en>de)');
      expect(result.destination, const OnDeviceDestination());
    });

    test('compare reports every network engine as a failure', () async {
      final entries = await repository.compare([
        googleEngine,
        claude,
        offlineEngine,
      ], englishToGerman).toList();
      expect(entries, hasLength(3));
      expect(entries.where((e) => e.isSuccess).map((e) => e.id), [
        offlineEngine.id,
      ]);
      for (final entry in entries.where((e) => !e.isSuccess)) {
        expect(entry.error, consent(ConsentKind.offlineOnly));
      }
      expectNoNetwork();
    });

    test('every AI request method fails without a request', () async {
      final calls = <Future<Object?> Function()>[
        () => repository.getAlternatives(claude, englishToGerman, 'Hallo'),
        () => repository.getInsights(claude, englishToGerman, 'Hallo'),
        () => repository.getSuggestions(claude, englishToGerman, 'Hallo'),
        () => repository.explain(claude, englishToGerman, 'Hallo').toList(),
        () =>
            repository.lookUp(claude, 'Haus', source: german, target: english),
        () => repository
            .refine(
              claude,
              englishToGerman,
              currentTranslation: 'Hallo',
              instruction: 'Shorter',
            )
            .toList(),
        () => repository.romanize(
          claude,
          text: 'こんにちは',
          language: const Language(code: 'ja', name: 'Japanese'),
        ),
        () => repository.align(
          claude,
          source: 'Hello',
          translation: 'Hallo',
          sourceLanguage: english,
          targetLanguage: german,
        ),
        () => repository.checkMeaning(
          claude,
          source: 'Hello',
          translation: 'Hallo',
          sourceLanguage: english,
          targetLanguage: german,
        ),
        () => repository.backTranslate(
          googleEngine,
          translation: 'Hallo',
          from: german,
          to: english,
        ),
        () => repository.proofread(claude, 'Helo'),
        () => repository.detectLanguage('Hallo', engine: claude),
        () => repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        () => repository.translateImage(
          aiEngine(visionClaude),
          Uint8List(4),
          mimeType: 'image/png',
          source: english,
          target: german,
        ),
        () => repository.translateImage(
          googleEngine,
          Uint8List(4),
          mimeType: 'image/png',
          source: english,
          target: german,
        ),
      ];
      configure(providers: [visionClaude]);
      for (final call in calls) {
        await expectLater(call(), throwsA(consent(ConsentKind.offlineOnly)));
      }
      expectNoNetwork();
    });

    test('language detection without an AI engine uses the device', () async {
      offline.identified = 'de';
      expect((await repository.detectLanguage('Hallo')).code, 'de');
      expectNoNetwork();
    });

    test('language detection fails without an on-device identifier', () async {
      repository.dispose();
      repository = newRepository()
        ..updateConfiguration(instances: [instanceA], providers: [])
        ..updatePrivacy(mode: PrivacyMode.offlineOnly);
      await expectLater(
        repository.detectLanguage('Hallo'),
        throwsA(consent(ConsentKind.offlineOnly, engineId: 'mozhi:google')),
      );
      expectNoNetwork();
    });

    test('engine lists are not loaded over the network', () async {
      final engines = await repository.getEngines(refresh: true);
      expect(engines.map((e) => e.id), [
        'ai:claude',
        'ai:ollama',
        'mt:deepl',
        'mt:libre',
        'ai:cloud-gemma',
        'offline:mlkit',
      ]);
      expectNoNetwork();
    });

    test('without other engines the list fails', () async {
      repository.dispose();
      repository = newRepository()
        ..updateConfiguration(instances: [instanceA], providers: [])
        ..updatePrivacy(mode: PrivacyMode.offlineOnly);
      await expectLater(
        repository.getEngines(),
        throwsA(
          consent(
            ConsentKind.offlineOnly,
            engineId: 'mozhi:',
            destination: const PublicInstanceDestination('a.example'),
          ),
        ),
      );
      expectNoNetwork();
    });

    test('stored Mozhi lists are served without revalidation', () async {
      final store = MemoryMetadataStore();
      repository.dispose();
      repository = newRepository(store: store)
        ..updateConfiguration(instances: [instanceA], providers: [])
        ..updatePrivacy(
          mode: PrivacyMode.online,
          consentedProviders: testProviderIds,
        );
      when(a().getEngines).thenAnswer((_) async => {'google': 'Google'});
      when(() => a().getSourceLanguages('google')).thenAnswer(
        (_) async => const [MozhiLanguage(id: 'en', name: 'English')],
      );
      await repository.getEngines();
      await repository.getSourceLanguages(googleEngine);
      await pumpEventQueue();
      repository.dispose();
      clientsBuilt.clear();
      repository = newRepository(store: store)
        ..updateConfiguration(instances: [instanceA], providers: [])
        ..updatePrivacy(mode: PrivacyMode.offlineOnly);
      reset(a());

      expect((await repository.getEngines()).map((e) => e.id), [
        'mozhi:google',
      ]);
      expect(
        (await repository.getSourceLanguages(googleEngine)).map((l) => l.code),
        ['en'],
      );
      await expectLater(
        repository.getTargetLanguages(googleEngine),
        throwsA(consent(ConsentKind.offlineOnly, engineId: 'mozhi:google')),
      );
      await pumpEventQueue();
      expectNoNetwork();
    });

    test('machine translation language lists need the network', () async {
      await expectLater(
        repository.getSourceLanguages(deeplMt),
        throwsA(consent(ConsentKind.offlineOnly, engineId: 'mt:deepl')),
      );
      await expectLater(
        repository.getTargetLanguages(libreMt),
        throwsA(consent(ConsentKind.offlineOnly, engineId: 'mt:libre')),
      );
      expectNoNetwork();
    });

    test('machine translation lists in memory are still served', () async {
      repository.updatePrivacy(mode: PrivacyMode.online);
      stubDeeplLanguages();
      await repository.getSourceLanguages(deeplMt);
      repository.updatePrivacy(mode: PrivacyMode.offlineOnly);
      expect(
        (await repository.getSourceLanguages(deeplMt)).map((l) => l.code),
        ['auto', 'en', 'de'],
      );
      verify(() => deepl.languages(type: DeeplLanguageType.source)).called(1);
    });

    test('allowOnce cannot override it', () {
      expect(
        () => repository.allowOnce(
          const ConsentRequiredException(
            kind: ConsentKind.offlineOnly,
            destination: PublicInstanceDestination('a.example'),
            engineId: 'mozhi:google',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('offline first', () {
    setUp(
      () => repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        consentedProviders: testProviderIds,
      ),
    );

    test('an unapproved pair needs consent', () async {
      await expectLater(
        repository.translate(googleEngine, englishToGerman),
        emitsError(
          consent(
            ConsentKind.pair,
            engineId: 'mozhi:google',
            destination: const PublicInstanceDestination(
              'a.example',
              engine: 'google',
            ),
            source: 'en',
            target: 'de',
          ),
        ),
      );
      expectNoNetwork();
    });

    test('an approved pair goes out', () async {
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['en>de'],
      );
      stubMozhi(a());
      expect((await finalResult(googleEngine, englishToGerman)).text, 'Hallo');
    });

    test('an auto source is its own pair', () async {
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['en>de'],
      );
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(consent(ConsentKind.pair, source: 'auto', target: 'de')),
      );
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['auto>de'],
      );
      stubMozhi(a());
      expect((await finalResult(googleEngine, autoToGerman)).text, 'Hallo');
    });

    test('self-hosted servers need the approval too', () async {
      configure(instances: [lanInstance]);
      await expectLater(
        repository.translate(googleEngine, englishToGerman),
        emitsError(
          consent(
            ConsentKind.pair,
            destination: const SelfHostedDestination('192.168.1.10'),
          ),
        ),
      );
      await expectLater(
        repository.translate(ollama, englishToGerman),
        emitsError(
          consent(
            ConsentKind.pair,
            destination: const SelfHostedDestination('localhost'),
          ),
        ),
      );
      expectNoNetwork();
    });

    test('the offline engine needs nothing', () async {
      expect(
        (await finalResult(offlineEngine, englishToGerman)).text,
        'Hello world (en>de)',
      );
    });

    test('cached network results are not served without consent', () async {
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['en>de'],
      );
      stubMozhi(a());
      await finalResult(googleEngine, englishToGerman);
      repository.updatePrivacy(mode: PrivacyMode.offlineFirst);
      await expectLater(
        repository.translate(googleEngine, englishToGerman),
        emitsError(consent(ConsentKind.pair)),
      );
    });

    test('single-language requests use the language twice', () async {
      await expectLater(
        repository.romanize(
          claude,
          text: 'こんにちは',
          language: const Language(code: 'ja', name: 'Japanese'),
        ),
        throwsA(consent(ConsentKind.pair, source: 'ja', target: 'ja')),
      );
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(
          consent(
            ConsentKind.pair,
            engineId: 'mozhi:google',
            source: 'de',
            target: 'de',
          ),
        ),
      );
      await expectLater(
        repository.proofread(claude, 'Helo'),
        throwsA(consent(ConsentKind.pair, source: 'auto', target: 'auto')),
      );
      expectNoNetwork();
    });

    test('Mozhi detection prefers the device when not allowed', () async {
      offline.identified = 'de';
      expect((await repository.detectLanguage('Hallo')).code, 'de');
      expectNoNetwork();
    });

    test('Mozhi detection with consent', () async {
      repository.dispose();
      repository = newRepository()
        ..updateConfiguration(instances: [instanceA], providers: [])
        ..updatePrivacy(mode: PrivacyMode.offlineFirst);
      await expectLater(
        repository.detectLanguage('Hallo'),
        throwsA(consent(ConsentKind.pair, source: 'auto', target: 'auto')),
      );
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['auto>auto'],
      );
      stubMozhi(a());
      expect((await repository.detectLanguage('Hallo')).code, 'en');
    });
  });

  group('offline-first lists', () {
    late MemoryMetadataStore store;

    Future<void> storeLists() async {
      repository.dispose();
      store = MemoryMetadataStore();
      repository = newRepository(store: store)
        ..updateConfiguration(instances: [instanceA], providers: [])
        ..updatePrivacy(mode: PrivacyMode.online);
      when(a().getEngines).thenAnswer((_) async => {'google': 'Google'});
      when(() => a().getSourceLanguages('google')).thenAnswer(
        (_) async => const [MozhiLanguage(id: 'en', name: 'English')],
      );
      when(() => a().getTargetLanguages('google')).thenAnswer(
        (_) async => const [MozhiLanguage(id: 'de', name: 'German')],
      );
      await repository.getEngines();
      await repository.getSourceLanguages(googleEngine);
      await repository.getTargetLanguages(googleEngine);
      await pumpEventQueue();
      repository.dispose();
      clientsBuilt.clear();
      reset(a());
    }

    TranslationRepository relaunch({
      PrivacyMode mode = PrivacyMode.offlineFirst,
    }) => repository = newRepository(store: store)
      ..updateConfiguration(instances: [instanceA], providers: [])
      ..updatePrivacy(mode: mode);

    test('are served from storage, of any age, without a request', () async {
      await storeLists();
      now = now.add(const Duration(days: 30));
      relaunch();
      expect(repository.metadataDeferred, isTrue);
      expect((await repository.getEngines()).map((e) => e.id), [
        'mozhi:google',
      ]);
      expect(
        (await repository.getTargetLanguages(googleEngine)).map((l) => l.code),
        ['de'],
      );
      await pumpEventQueue();
      expectNoNetwork();
    });

    test('without stored lists, Mozhi engines are left out', () async {
      expect(repository.metadataDeferred, isTrue);
      final engines = await repository.getEngines();
      expect(engines.map((e) => e.id), isNot(contains('mozhi:google')));
      await expectLater(
        repository.getSourceLanguages(googleEngine),
        throwsA(
          consent(ConsentKind.pair, engineId: 'mozhi:google')
              .having((e) => e.source, 'source', isNull)
              .having((e) => e.target, 'target', isNull),
        ),
      );
      expectNoNetwork();
    });

    test('allowMetadataRequests lets them load', () async {
      when(a().getEngines).thenAnswer((_) async => {'google': 'Google'});
      repository.allowMetadataRequests();
      expect(repository.metadataDeferred, isFalse);
      expect(
        (await repository.getEngines()).map((e) => e.id),
        contains('mozhi:google'),
      );
    });

    test('a refresh lets them load', () async {
      when(a().getEngines).thenAnswer((_) async => {'google': 'Google'});
      expect(
        (await repository.getEngines(refresh: true)).map((e) => e.id),
        contains('mozhi:google'),
      );
      expect(repository.metadataDeferred, isFalse);
    });

    test('an approved request lets them load and announces it', () async {
      await storeLists();
      relaunch();
      final changes = <void>[];
      repository.metadataChanged.listen(changes.add);
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['en>de'],
      );
      stubMozhi(a());
      await finalResult(googleEngine, englishToGerman);
      await pumpEventQueue();
      expect(repository.metadataDeferred, isFalse);
      expect(changes, hasLength(1));
      when(a().getEngines).thenAnswer((_) async => {'deepl': 'DeepL'});
      await repository.getEngines();
      await pumpEventQueue();
      verify(a().getEngines).called(1);
    });

    test('are not deferred online', () async {
      await storeLists();
      relaunch(mode: PrivacyMode.online);
      when(a().getEngines).thenAnswer((_) async => {'google': 'Google'});
      expect(repository.metadataDeferred, isFalse);
      await repository.getEngines();
      await pumpEventQueue();
      verify(a().getEngines).called(1);
    });
  });

  group('cloud providers', () {
    for (final mode in PrivacyMode.values.where(
      (m) => m != PrivacyMode.offlineOnly,
    )) {
      test('need consent in ${mode.name} mode', () async {
        repository.updatePrivacy(mode: mode, approvedPairs: ['en>de']);
        for (final engine in [claude, deeplMt]) {
          await expectLater(
            repository.translate(engine, englishToGerman),
            emitsError(
              consent(
                ConsentKind.cloudProvider,
                engineId: engine.id,
                source: 'en',
                target: 'de',
              ),
            ),
          );
        }
        await expectLater(
          repository.getInsights(claude, englishToGerman, 'Hallo'),
          throwsA(consent(ConsentKind.cloudProvider)),
        );
        expectNoNetwork();
      });
    }

    test('consented providers are used', () async {
      repository.updatePrivacy(
        mode: PrivacyMode.online,
        consentedProviders: ['claude'],
      );
      stubStream(claudeClient(), ['Hallo']);
      expect((await finalResult(claude, englishToGerman)).text, 'Hallo');
    });

    test('local providers need no provider consent', () async {
      repository.updatePrivacy(mode: PrivacyMode.online);
      stubStream(ollamaClient(), ['Hallo']);
      stubLibre();
      expect((await finalResult(ollama, englishToGerman)).text, 'Hallo');
      expect((await finalResult(libreMt, englishToGerman)).text, 'Hallo');
    });

    test('the provider is asked before the pair', () async {
      repository.updatePrivacy(mode: PrivacyMode.offlineFirst);
      await expectLater(
        repository.translate(claude, englishToGerman),
        emitsError(consent(ConsentKind.cloudProvider)),
      );
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        consentedProviders: ['claude'],
      );
      await expectLater(
        repository.translate(claude, englishToGerman),
        emitsError(consent(ConsentKind.pair)),
      );
    });
  });

  group('allowOnce', () {
    ConsentRequiredException caught(Object error) =>
        error as ConsentRequiredException;

    Future<ConsentRequiredException> denial(
      TranslationEngine engine,
      TranslationRequest request,
    ) async {
      try {
        await repository.translate(engine, request).drain<void>();
      } on ConsentRequiredException catch (error) {
        return error;
      }
      fail('Expected a ConsentRequiredException');
    }

    setUp(() => repository.updatePrivacy(mode: PrivacyMode.offlineFirst));

    test('lets exactly the next matching request through', () async {
      stubMozhi(a());
      final denied = await denial(googleEngine, englishToGerman);
      repository.allowOnce(denied);
      expect((await finalResult(googleEngine, englishToGerman)).text, 'Hallo');
      await expectLater(
        repository.translate(googleEngine, englishToGerman),
        emitsError(consent(ConsentKind.pair)),
      );
      verify(
        () => a().translate(
          engine: 'google',
          from: 'en',
          to: 'de',
          text: 'Hello world',
          abortTrigger: any(named: 'abortTrigger'),
        ),
      ).called(1);
    });

    test('only covers its engine and pair', () async {
      final denied = await denial(googleEngine, englishToGerman);
      repository.allowOnce(denied);
      await expectLater(
        repository.translate(deeplEngine, englishToGerman),
        emitsError(consent(ConsentKind.pair)),
      );
      await expectLater(
        repository.translate(googleEngine, autoToGerman),
        emitsError(consent(ConsentKind.pair)),
      );
      expectNoNetwork();
      stubMozhi(a());
      expect((await finalResult(googleEngine, englishToGerman)).text, 'Hallo');
    });

    test('lets a job of several requests through', () async {
      stubMozhi(a());
      final denied = await denial(googleEngine, englishToGerman);
      repository.allowOnce(denied, requests: 2);
      now = now.add(const Duration(minutes: 1));
      await finalResult(googleEngine, englishToGerman);
      // Each use keeps the approval alive.
      now = now.add(const Duration(minutes: 1, seconds: 30));
      await finalResult(
        googleEngine,
        englishToGerman.copyWith(text: 'Second part'),
      );
      await expectLater(
        repository.translate(googleEngine, englishToGerman),
        emitsError(consent(ConsentKind.pair)),
      );
      expect(() => repository.allowOnce(denied, requests: 0), throwsRangeError);
    });

    test('expires', () async {
      final denied = await denial(googleEngine, englishToGerman);
      repository.allowOnce(denied);
      now = now.add(TranslationRepository.consentOnceLifetime);
      await expectLater(
        repository.translate(googleEngine, englishToGerman),
        emitsError(consent(ConsentKind.pair)),
      );
      expectNoNetwork();
    });

    test('a provider approval does not approve the pair', () async {
      final provider = await denial(claude, englishToGerman);
      expect(provider.kind, ConsentKind.cloudProvider);
      repository.allowOnce(provider);
      final pair = await denial(claude, englishToGerman);
      expect(pair.kind, ConsentKind.pair);
      repository.allowOnce(pair);
      // The provider approval was used up by the request the pair stopped.
      expect(
        (await denial(claude, englishToGerman)).kind,
        ConsentKind.cloudProvider,
      );
      repository
        ..updatePrivacy(
          mode: PrivacyMode.offlineFirst,
          consentedProviders: ['claude'],
        )
        ..allowOnce(pair);
      stubStream(claudeClient(), ['Hallo']);
      expect((await finalResult(claude, englishToGerman)).text, 'Hallo');
    });

    test("covers the failover within the user's list", () async {
      whenTranslate(a()).thenThrow(serverError());
      stubMozhi(b());
      repository.allowOnce(await denial(googleEngine, englishToGerman));
      final result = await finalResult(googleEngine, englishToGerman);
      expect(
        result.destination,
        const PublicInstanceDestination('b.example', engine: 'google'),
      );
    });

    test('works for the other request methods', () async {
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        consentedProviders: ['claude'],
      );
      stubChat(claudeClient(), '{"insights": []}');
      Object? error;
      try {
        await repository.getInsights(claude, englishToGerman, 'Hallo');
      } on ConsentRequiredException catch (e) {
        error = e;
      }
      repository.allowOnce(caught(error!));
      expect(
        await repository.getInsights(claude, englishToGerman, 'Hallo'),
        isEmpty,
      );
    });
  });

  group('Mozhi failover', () {
    test('stops when offline only is turned on meanwhile', () async {
      repository.updatePrivacy(mode: PrivacyMode.online);
      whenTranslate(a()).thenAnswer((_) async {
        repository.updatePrivacy(mode: PrivacyMode.offlineOnly);
        throw serverError();
      });
      stubMozhi(b());
      await expectLater(
        repository.translate(googleEngine, englishToGerman),
        emitsError(isA<MozhiApiException>()),
      );
      verifyZeroInteractions(b());
    });

    test('moves on to allowed instances', () async {
      configure(instances: [lanInstance, instanceA]);
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['en>de'],
      );
      whenTranslate(lan()).thenThrow(serverError());
      stubMozhi(a());
      final result = await finalResult(googleEngine, englishToGerman);
      expect(
        result.destination,
        const PublicInstanceDestination('a.example', engine: 'google'),
      );
    });
  });

  group('no silent switch to another destination', () {
    test(
      'detection for a cloud MT model skips Mozhi without approval',
      () async {
        offline.identified = null;
        repository.updatePrivacy(
          mode: PrivacyMode.offlineFirst,
          consentedProviders: ['cloud-gemma'],
        );
        Object? denied;
        try {
          await repository.translate(cloudGemma, autoToGerman).drain<void>();
        } on ConsentRequiredException catch (error) {
          denied = error;
        }
        repository.allowOnce(denied! as ConsentRequiredException);
        await expectLater(
          repository.translate(cloudGemma, autoToGerman),
          emitsError(
            isA<SourceLanguageRequiredException>().having(
              (e) => e.cause,
              'cause',
              consent(ConsentKind.pair, engineId: 'mozhi:google'),
            ),
          ),
        );
        verifyZeroInteractions(a());
      },
    );

    test('detection for a cloud MT model uses Mozhi when allowed', () async {
      offline.identified = null;
      repository.updatePrivacy(
        mode: PrivacyMode.online,
        consentedProviders: ['cloud-gemma'],
      );
      stubMozhi(a());
      stubStream(llm['mt.example.com']!, ['Hallo Welt']);
      final result = await finalResult(cloudGemma, autoToGerman);
      expect(result.detectedSource, 'en');
    });

    test('Reverso speech is only tried when allowed', () async {
      when(
        () => a().textToSpeech(
          engine: any(named: 'engine'),
          language: any(named: 'language'),
          text: any(named: 'text'),
        ),
      ).thenThrow(serverError());
      when(
        () => b().textToSpeech(
          engine: any(named: 'engine'),
          language: any(named: 'language'),
          text: any(named: 'text'),
        ),
      ).thenThrow(serverError());
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: ['de>de'],
      );
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(isA<MozhiApiException>()),
      );
      verify(
        () =>
            a().textToSpeech(engine: 'reverso', language: 'de', text: 'Hallo'),
      ).called(1);

      // With a one-time approval for Google only, Reverso is not asked.
      clearInteractions(a());
      clearInteractions(b());
      repository.updatePrivacy(mode: PrivacyMode.offlineFirst);
      try {
        await repository.textToSpeech(text: 'Hallo', languageCode: 'de');
      } on ConsentRequiredException catch (error) {
        repository.allowOnce(error);
      }
      await expectLater(
        repository.textToSpeech(text: 'Hallo', languageCode: 'de'),
        throwsA(isA<MozhiApiException>()),
      );
      verifyNever(
        () =>
            a().textToSpeech(engine: 'reverso', language: 'de', text: 'Hallo'),
      );
    });

    test('compare checks every engine on its own', () async {
      repository.updatePrivacy(
        mode: PrivacyMode.online,
        consentedProviders: ['ollama'],
      );
      stubMozhi(a());
      final entries = await repository.compare([
        googleEngine,
        claude,
      ], englishToGerman).toList();
      final byId = {for (final entry in entries) entry.id: entry};
      expect(byId['mozhi:google']!.isSuccess, isTrue);
      expect(byId['ai:claude']!.error, consent(ConsentKind.cloudProvider));
      verifyZeroInteractions(claudeClient());
    });
  });
}
