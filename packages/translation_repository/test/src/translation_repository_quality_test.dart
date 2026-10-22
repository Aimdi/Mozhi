import 'dart:async';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

/// The translation checks, placeholder masking, personal data shield,
/// chunking of non-AI engines, DeepL glossaries and model, AI retries and
/// temperature, and the on-device-first detection hint.
void main() {
  setUpAll(registerTestFallbacks);

  late MockMozhiApiClient mozhi;
  late Map<String, MockLlmClient> llm;
  late MockDeeplClient deepl;
  late MockLibreTranslateClient libre;
  late TranslationRepository repository;

  const plainOpenAi = AiProviderConfig(
    id: 'openai',
    name: 'OpenAI',
    provider: LlmProvider.openAiCompatible,
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-4.1',
    apiKey: 'sk',
  );

  MockLlmClient llmOf(AiProviderConfig config) =>
      llm[Uri.parse(config.baseUrl).host]!;

  TranslationRepository newRepository({
    List<AiProviderConfig> providers = const [
      claudeConfig,
      plainOpenAi,
      ollamaConfig,
      deeplConfig,
      libreConfig,
    ],
    FakeOfflineTranslator? device,
    int aiChunkThreshold = TranslationRepository.defaultAiChunkThreshold,
  }) {
    final repository = allowNetwork(
      TranslationRepository(
        mozhiClientFactory: (_) => mozhi,
        llmClientFactory: (endpoint) => llm[endpoint.baseUrl.host]!,
        deeplClientFactory: (_) => deepl,
        libreTranslateClientFactory: (_) => libre,
        offline: device,
        snapshotInterval: Duration.zero,
        aiChunkThreshold: aiChunkThreshold,
      ),
    )..updateConfiguration(instances: const [instanceA], providers: providers);
    addTearDown(repository.dispose);
    return repository;
  }

  setUp(() {
    mozhi = MockMozhiApiClient();
    llm = {
      for (final config in [claudeConfig, plainOpenAi, ollamaConfig])
        Uri.parse(config.baseUrl).host: MockLlmClient(),
    };
    deepl = MockDeeplClient();
    libre = MockLibreTranslateClient();
    repository = newRepository();
  });

  // Mozhi.

  final sentToMozhi = <String>[];

  When<Future<MozhiTranslation>> whenMozhi() => when(
    () => mozhi.translate(
      engine: any(named: 'engine'),
      from: any(named: 'from'),
      to: any(named: 'to'),
      text: any(named: 'text'),
      abortTrigger: any(named: 'abortTrigger'),
    ),
  );

  /// Mozhi answers every text with [translate] of it.
  void stubMozhi(String Function(String text) translate, {String? detected}) {
    sentToMozhi.clear();
    whenMozhi().thenAnswer((invocation) async {
      final text = invocation.namedArguments[#text] as String;
      sentToMozhi.add(text);
      return MozhiTranslation(
        engine: invocation.namedArguments[#engine] as String,
        translatedText: translate(text),
        detectedLanguage: detected ?? '',
      );
    });
  }

  String toGerman(String text) => text
      .replaceAll('Write to', 'Schreib an')
      .replaceAll('Call', 'Ruf')
      .replaceAll('about', 'über')
      .replaceAll('today', 'heute')
      .replaceAll('the plan', 'den Plan');

  const englishToGerman = TranslationRequest(
    text: 'Write to jane@x.org about <b>{name}</b> today',
    source: english,
    target: german,
  );

  group('Mozhi masking', () {
    test('masks formatting and personal data, then restores them', () async {
      stubMozhi(toGerman);
      final result = await repository
          .translate(googleEngine, englishToGerman)
          .single;
      expect(sentToMozhi.single, 'Write to ⟨1⟩ about ⟨2⟩⟨3⟩⟨4⟩ today');
      expect(result.text, 'Schreib an jane@x.org über <b>{name}</b> heute');
      expect(result.maskedPersonalData, 1);
      expect(result.warnings, isEmpty);
    });

    test('sends personal data as it is with the shield off', () async {
      repository.updatePrivacy(
        mode: PrivacyMode.online,
        consentedProviders: testProviderIds,
        maskPersonalData: false,
      );
      expect(repository.maskPersonalData, isFalse);
      stubMozhi(toGerman);
      const request = TranslationRequest(
        text: 'Call +49 30 1234567 about the plan today',
        source: english,
        target: german,
      );
      final result = await repository.translate(googleEngine, request).single;
      expect(sentToMozhi.single, request.text);
      expect(result.text, 'Ruf +49 30 1234567 über den Plan heute');
      expect(result.maskedPersonalData, 0);
      // updatePrivacy without the flag keeps it.
      allowNetwork(repository);
      expect(repository.maskPersonalData, isFalse);
      repository
        ..maskPersonalData = true
        ..clearCache();
      await repository.translate(googleEngine, request).drain<void>();
      expect(sentToMozhi.last, 'Call ⟨1⟩ about the plan today');
    });

    test('resends damaged tokens with only the personal data masked', () async {
      sentToMozhi.clear();
      whenMozhi().thenAnswer((invocation) async {
        final text = invocation.namedArguments[#text] as String;
        sentToMozhi.add(text);
        // The first answer loses the formatting tokens.
        final answer = sentToMozhi.length == 1
            ? toGerman(text).replaceAll(RegExp('⟨[234]⟩'), '')
            : toGerman(text);
        return MozhiTranslation(engine: 'google', translatedText: answer);
      });
      final result = await repository
          .translate(googleEngine, englishToGerman)
          .single;
      expect(sentToMozhi, [
        'Write to ⟨1⟩ about ⟨2⟩⟨3⟩⟨4⟩ today',
        'Write to ⟨1⟩ about <b>{name}</b> today',
      ]);
      expect(result.text, 'Schreib an jane@x.org über <b>{name}</b> heute');
      expect(result.warnings, isEmpty);
      expect(result.maskedPersonalData, 1);
    });

    test('resends plain text when no personal data was masked', () async {
      repository.maskPersonalData = false;
      sentToMozhi.clear();
      whenMozhi().thenAnswer((invocation) async {
        final text = invocation.namedArguments[#text] as String;
        sentToMozhi.add(text);
        return MozhiTranslation(
          engine: 'google',
          translatedText: toGerman(text).replaceAll('⟨2⟩', ''),
        );
      });
      final result = await repository
          .translate(googleEngine, englishToGerman)
          .single;
      expect(sentToMozhi.last, englishToGerman.text);
      expect(result.text, 'Schreib an jane@x.org über <b>{name}</b> heute');
    });

    test('never sends lost personal data unmasked', () async {
      stubMozhi((text) => toGerman(text).replaceAll('⟨1⟩', '(1)'));
      const request = TranslationRequest(
        text: 'Call +49 30 1234567 about the plan today',
        source: english,
        target: german,
      );
      final result = await repository.translate(googleEngine, request).single;
      expect(sentToMozhi, ['Call ⟨1⟩ about the plan today']);
      expect(result.text, 'Ruf (1) über den Plan heute');
      expect(
        result.warnings.map((w) => w.kind),
        contains(TranslationWarningKind.personalDataLost),
      );
      expect(result.maskedPersonalData, 1);
    });

    test('a lost personal token after a resend is reported', () async {
      stubMozhi((text) => toGerman(text).replaceAll(RegExp(r'⟨\d⟩'), ''));
      final result = await repository
          .translate(googleEngine, englishToGerman)
          .single;
      expect(sentToMozhi, hasLength(2));
      expect(
        result.warnings.map((w) => w.kind),
        contains(TranslationWarningKind.personalDataLost),
      );
    });

    test('restores tokens in transliterations', () async {
      whenMozhi().thenAnswer(
        (_) async => const MozhiTranslation(
          engine: 'google',
          translatedText: 'Привет ⟨1⟩',
          targetTransliteration: 'Privet ⟨1⟩',
          sourceTransliteration: 'Hi ⟨1⟩',
        ),
      );
      final result = await repository
          .translate(
            googleEngine,
            const TranslationRequest(
              text: 'Hi {name}',
              source: english,
              target: Language(code: 'ru', name: 'Russian'),
            ),
          )
          .single;
      expect(result.text, 'Привет {name}');
      expect(result.targetTransliteration, 'Privet {name}');
      expect(result.sourceTransliteration, 'Hi {name}');
    });

    test('masks nothing without preserveFormatting nor personal data', () {
      stubMozhi(toGerman);
      return repository
          .translate(
            googleEngine,
            englishToGerman.copyWith(
              text: 'About <b>{name}</b> today',
              options: const TranslationOptions(preserveFormatting: false),
            ),
          )
          .drain<void>()
          .then((_) {
            expect(sentToMozhi.single, 'About <b>{name}</b> today');
          });
    });

    test('the offline engine always gets the text as it is', () async {
      final device = FakeOfflineTranslator();
      repository = newRepository(device: device);
      final result = await repository
          .translate(TranslationEngine.offline(), englishToGerman)
          .single;
      expect(device.calls.single.text, englishToGerman.text);
      expect(result.maskedPersonalData, 0);
    });
  });

  group('Mozhi chunking', () {
    final paragraphs = [
      for (final word in ['first', 'second', 'third'])
        'The $word paragraph is here and it is long. ' * 6,
    ].map((p) => p.trim()).toList();

    test('splits at paragraphs by the engine limit, one at a time', () async {
      stubMozhi((text) => text.replaceAll('paragraph', 'Absatz'));
      final engine = TranslationEngine.mozhi('mymemory', 'MyMemory');
      final results = await repository
          .translate(
            engine,
            TranslationRequest(
              text: paragraphs.join('\n\n'),
              source: english,
              target: german,
            ),
          )
          .toList();
      expect(sentToMozhi, paragraphs);
      expect(results.where((r) => !r.isComplete), isNotEmpty);
      expect(results.last.isComplete, isTrue);
      expect(
        results.last.text,
        paragraphs.map((p) => p.replaceAll('paragraph', 'Absatz')).join('\n\n'),
      );
      expect(results.last.destination, isNotNull);
    });

    test('limits and concurrency per engine', () {
      expect(TranslationRepository.mozhiCharacterLimit('google'), 4500);
      expect(TranslationRepository.mozhiCharacterLimit('DeepL'), 1500);
      expect(TranslationRepository.mozhiCharacterLimit('mymemory'), 450);
      expect(TranslationRepository.mozhiCharacterLimit('duckduckgo'), 1000);
      expect(TranslationRepository.mozhiCharacterLimit('libre'), 2000);
      expect(TranslationRepository.mozhiCharacterLimit('yandex'), 4500);
      expect(TranslationRepository.mozhiCharacterLimit('reverso'), 1500);
      expect(TranslationRepository.mozhiCharacterLimit('other'), 1500);
      expect(TranslationRepository.mozhiConcurrency('google'), 2);
      expect(TranslationRepository.mozhiConcurrency('deepl'), 1);
    });

    test('counts the personal data of every part', () async {
      stubMozhi(toGerman);
      final engine = TranslationEngine.mozhi('mymemory', 'MyMemory');
      final result = await repository
          .translate(
            engine,
            TranslationRequest(
              text: '${paragraphs[0]} a@b.de\n\n${paragraphs[1]} c@d.de',
              source: english,
              target: german,
            ),
          )
          .last;
      expect(sentToMozhi.every((text) => text.endsWith('⟨1⟩')), isTrue);
      expect(result.text, contains('a@b.de'));
      expect(result.text, contains('c@d.de'));
      expect(result.maskedPersonalData, 2);
    });
  });

  group('checks', () {
    test('final results carry warnings', () async {
      stubMozhi((_) => 'Ruf heute an');
      final result = await repository
          .translate(
            googleEngine,
            const TranslationRequest(
              text: 'Call 0800 today',
              source: english,
              target: german,
            ),
          )
          .single;
      expect(result.warnings.map((w) => w.kind), [
        TranslationWarningKind.numbers,
      ]);
    });

    test('suspect results are not cached', () async {
      const request = TranslationRequest(
        text: 'The weather is nice today and we go out.',
        source: english,
        target: german,
      );
      stubMozhi((text) => text);
      final first = await repository.translate(googleEngine, request).single;
      expect(first.isSuspect, isTrue);
      final second = await repository.translate(googleEngine, request).single;
      expect(second.fromCache, isFalse);
      expect(sentToMozhi, hasLength(2));
    });

    test('the device finds output still in the source language', () async {
      final device = FakeOfflineTranslator(identified: 'en');
      repository = newRepository(device: device);
      stubMozhi((_) => 'The weather is nice and we are going out today.');
      const request = TranslationRequest(
        text: 'The weather is nice today and we go out.',
        source: english,
        target: german,
      );
      final result = await repository.translate(googleEngine, request).single;
      expect(result.warnings.map((w) => w.kind), [
        TranslationWarningKind.wrongLanguage,
      ]);
      device.identified = 'de';
      repository.clearCache();
      final fine = await repository
          .translate(googleEngine, request, refresh: true)
          .single;
      expect(fine.warnings, isEmpty);
      // Not for short output, nor for the offline engine.
      device.identified = 'en';
      stubMozhi((_) => 'Nice weather.');
      final short = await repository
          .translate(googleEngine, request, refresh: true)
          .single;
      expect(
        short.warnings.map((w) => w.kind),
        isNot(contains(TranslationWarningKind.wrongLanguage)),
      );
    });

    test('the device check ignores identifier failures', () async {
      final device = _ThrowingIdentifier();
      repository = newRepository(device: device);
      stubMozhi((_) => 'The weather is nice and we are going out today.');
      final result = await repository
          .translate(
            googleEngine,
            const TranslationRequest(
              text: 'The weather is nice today and we go out.',
              source: english,
              target: german,
            ),
          )
          .single;
      expect(result.warnings, isEmpty);
    });
  });

  group('DeepL', () {
    final engine = mtEngine(deeplConfig);
    final sent =
        <
          ({
            String text,
            String? tags,
            String? glossary,
            String? source,
            String? model,
          })
        >[];

    void stubDeepl(String Function(String text) translate) {
      sent.clear();
      when(() => deepl.languages(type: any(named: 'type'))).thenAnswer(
        (_) async => const [DeeplLanguage(code: 'DE', name: 'German')],
      );
      when(
        () => deepl.translateText(
          text: any(named: 'text'),
          targetLang: any(named: 'targetLang'),
          sourceLang: any(named: 'sourceLang'),
          formality: any(named: 'formality'),
          context: any(named: 'context'),
          glossaryId: any(named: 'glossaryId'),
          preserveFormatting: any(named: 'preserveFormatting'),
          tagHandling: any(named: 'tagHandling'),
          modelType: any(named: 'modelType'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      ).thenAnswer((invocation) async {
        final text = invocation.namedArguments[#text] as String;
        sent.add((
          text: text,
          tags: invocation.namedArguments[#tagHandling] as String?,
          glossary: invocation.namedArguments[#glossaryId] as String?,
          source: invocation.namedArguments[#sourceLang] as String?,
          model: invocation.namedArguments[#modelType] as String?,
        ));
        return DeeplTranslation(
          text: translate(text),
          detectedSourceLanguage: 'EN',
        );
      });
    }

    test('gets masks as XML with tag_handling=xml', () async {
      stubDeepl((text) => text.replaceAll('Hi', 'Hallo'));
      final result = await repository
          .translate(
            engine,
            const TranslationRequest(
              text: 'Hi <b>Bob</b> & co',
              source: english,
              target: german,
            ),
          )
          .single;
      expect(sent.single.text, 'Hi <x i="1"/>Bob<x i="2"/> &amp; co');
      expect(sent.single.tags, 'xml');
      expect(result.text, 'Hallo <b>Bob</b> & co');
    });

    test('plain text goes without tag handling', () async {
      stubDeepl((text) => 'Hallo Welt');
      await repository
          .translate(
            engine,
            const TranslationRequest(
              text: 'Hello world',
              source: english,
              target: german,
            ),
          )
          .drain<void>();
      expect(sent.single.text, 'Hello world');
      expect(sent.single.tags, isNull);
      expect(sent.single.glossary, isNull);
      expect(sent.single.model, isNull);
    });

    const glossaryRequest = TranslationRequest(
      text: 'Restart the server today.',
      source: english,
      target: german,
      options: TranslationOptions(glossary: {'server': 'Rechner'}),
    );

    void stubGlossaries() {
      when(deepl.listGlossaries).thenAnswer((_) async => const []);
      when(
        () => deepl.createGlossary(
          name: any(named: 'name'),
          sourceLang: any(named: 'sourceLang'),
          targetLang: any(named: 'targetLang'),
          entries: any(named: 'entries'),
        ),
      ).thenAnswer(
        (_) async => const DeeplGlossary(
          id: 'g1',
          name: 'n',
          sourceLang: 'en',
          targetLang: 'de',
        ),
      );
    }

    test('uses a glossary when one of its terms occurs', () async {
      stubDeepl((_) => 'Starte den Rechner heute neu.');
      stubGlossaries();
      final result = await repository.translate(engine, glossaryRequest).single;
      expect(sent.single.glossary, 'g1');
      expect(sent.single.source, 'EN');
      expect(result.warnings, isEmpty);
      verify(
        () => deepl.createGlossary(
          name: any(named: 'name'),
          sourceLang: 'en',
          targetLang: 'de',
          entries: const {'server': 'Rechner'},
        ),
      ).called(1);
      // Reused.
      await repository
          .translate(engine, glossaryRequest.copyWith(text: 'A server.'))
          .drain<void>();
      verify(deepl.listGlossaries).called(1);
    });

    test('identifies an auto source on the device for a glossary', () async {
      final device = FakeOfflineTranslator(identified: 'en');
      repository = newRepository(device: device);
      stubDeepl((_) => 'Starte den Rechner heute neu.');
      stubGlossaries();
      final result = await repository
          .translate(engine, glossaryRequest.copyWith(source: Language.auto))
          .single;
      expect(sent.single.glossary, 'g1');
      expect(sent.single.source, 'EN');
      expect(result.detectedSource, 'en');
      expect(device.identifyCalls.first, glossaryRequest.text);
    });

    test('goes without a glossary when the source is unknown', () async {
      stubDeepl((_) => 'Starte den Server heute neu.');
      stubGlossaries();
      final result = await repository
          .translate(engine, glossaryRequest.copyWith(source: Language.auto))
          .single;
      expect(sent.single.glossary, isNull);
      expect(sent.single.source, isNull);
      // The check reports the unused term.
      expect(result.warnings.map((w) => w.kind), [
        TranslationWarningKind.glossary,
      ]);
    });

    test('makes no glossary when none of its terms occurs', () async {
      stubDeepl((_) => 'Hallo');
      stubGlossaries();
      await repository
          .translate(engine, glossaryRequest.copyWith(text: 'Hello there'))
          .drain<void>();
      verifyNever(deepl.listGlossaries);
      expect(sent.single.glossary, isNull);
    });

    test('prefers the quality-optimised model when asked', () async {
      repository = newRepository(
        providers: [deeplConfig.copyWith(preferQualityModel: true)],
      );
      stubDeepl((_) => 'Hallo Welt');
      await repository
          .translate(
            engine,
            const TranslationRequest(
              text: 'Hello world',
              source: english,
              target: german,
            ),
          )
          .drain<void>();
      expect(sent.single.model, DeeplModelType.preferQualityOptimized);
    });

    test('an unknown provider is a stream error', () {
      expect(
        repository.translate(
          mtEngine(deeplConfig).copyWithId('mt:nope'),
          englishToGerman,
        ),
        emitsError(isArgumentError),
      );
    });
  });

  test('LibreTranslate gets bracket tokens', () async {
    final sent = <String>[];
    when(libre.languages).thenAnswer((_) async => const []);
    when(
      () => libre.translate(
        text: any(named: 'text'),
        target: any(named: 'target'),
        source: any(named: 'source'),
        abortTrigger: any(named: 'abortTrigger'),
      ),
    ).thenAnswer((invocation) async {
      final text = invocation.namedArguments[#text] as String;
      sent.add(text);
      return LibreTranslation(text: toGerman(text));
    });
    final result = await repository
        .translate(mtEngine(libreConfig), englishToGerman)
        .single;
    expect(sent.single, 'Write to ⟨1⟩ about ⟨2⟩⟨3⟩⟨4⟩ today');
    expect(result.text, 'Schreib an jane@x.org über <b>{name}</b> heute');
  });

  group('AI', () {
    final openAi = aiEngine(plainOpenAi);
    final claude = aiEngine(claudeConfig);
    final requests = <LlmRequest>[];

    /// Answers the streamed requests with [answers], one per request.
    void stubAnswers(MockLlmClient client, List<Object> answers) {
      requests.clear();
      when(() => client.streamChat(any())).thenAnswer((invocation) {
        requests.add(invocation.positionalArguments.single as LlmRequest);
        final answer = answers[requests.length - 1];
        return answer is String ? Stream.value(answer) : Stream.error(answer);
      });
    }

    String sourceOf(LlmRequest request) =>
        RegExp(r'<source>\n([\s\S]*)\n</source>')
            .firstMatch(request.messages.last.content)![1]!;

    test('masks personal data in the prompt and restores it', () async {
      stubAnswers(llmOf(plainOpenAi), [
        'Schreib an ⟨1⟩ über <b>{name}</b> heute',
      ]);
      final results = await repository
          .translate(openAi, englishToGerman)
          .toList();
      expect(
        sourceOf(requests.single),
        'Write to ⟨1⟩ about <b>{name}</b> today',
      );
      expect(
        results.last.text,
        'Schreib an jane@x.org über <b>{name}</b> heute',
      );
      expect(results.last.maskedPersonalData, 1);
      expect(results.every((r) => !r.text.contains('⟨1⟩')), isTrue);
    });

    test('a lost personal token is reported after the retry', () async {
      stubAnswers(llmOf(plainOpenAi), [
        'Schreib an über <b>{name}</b> heute',
        'Schreib an über <b>{name}</b> heute!',
      ]);
      final result = await repository.translate(openAi, englishToGerman).last;
      expect(requests, hasLength(2));
      expect(
        result.warnings.map((w) => w.kind),
        contains(TranslationWarningKind.personalDataLost),
      );
    });

    test('retries once with a corrective note when a check fails', () async {
      stubAnswers(llmOf(plainOpenAi), [
        'Schreib an ⟨1⟩ über <b>Name</b> heute',
        'Schreib an ⟨1⟩ über <b>{name}</b> heute',
      ]);
      final results = await repository
          .translate(openAi, englishToGerman)
          .toList();
      expect(requests, hasLength(2));
      final retry = requests.last.messages;
      expect(retry.sublist(0, retry.length - 2), requests.first.messages);
      expect(
        retry[retry.length - 2],
        const LlmMessage.assistant('Schreib an ⟨1⟩ über <b>Name</b> heute'),
      );
      expect(retry.last.role, LlmRole.user);
      expect(retry.last.content, contains('placeholders'));
      expect(retry.last.content, isNot(contains('jane@x.org')));
      expect(results.where((r) => r.isComplete), hasLength(1));
      expect(
        results.last.text,
        'Schreib an jane@x.org über <b>{name}</b> heute',
      );
      expect(results.last.warnings, isEmpty);
    });

    test('keeps the first attempt when the retry is worse or fails', () async {
      repository.maskPersonalData = false;
      const request = TranslationRequest(
        text: 'Hello {name}, see you tomorrow at the station.',
        source: english,
        target: german,
      );
      stubAnswers(llmOf(plainOpenAi), [
        'Hallo, bis morgen am Bahnhof.',
        'Привет, до завтра на вокзале.',
      ]);
      final worse = await repository.translate(openAi, request).last;
      expect(worse.text, 'Hallo, bis morgen am Bahnhof.');
      stubAnswers(llmOf(plainOpenAi), [
        'Hallo, bis morgen am Bahnhof.',
        const LlmApiException('overloaded', statusCode: 529),
      ]);
      final failed = await repository
          .translate(openAi, request, refresh: true)
          .last;
      expect(failed.text, 'Hallo, bis morgen am Bahnhof.');
      expect(failed.warnings.map((w) => w.kind), [
        TranslationWarningKind.placeholders,
      ]);
    });

    test('does not retry a good translation', () async {
      stubAnswers(llmOf(plainOpenAi), [
        'Schreib an ⟨1⟩ über <b>{name}</b> heute',
      ]);
      await repository.translate(openAi, englishToGerman).drain<void>();
      expect(requests, hasLength(1));
    });

    group('glossary', () {
      TranslationRequest withIt(String text) => TranslationRequest(
        text: text,
        source: english,
        target: const Language(code: 'es', name: 'Spanish'),
        options: const TranslationOptions(glossary: {'IT': 'TI'}),
      );

      test('a word that only looks like a term asks for nothing', () async {
        stubAnswers(llmOf(plainOpenAi), [
          '¿Está listo? Lo necesitamos hoy mismo.',
        ]);
        final result = await repository
            .translate(openAi, withIt('Is it ready? We need it today.'))
            .last;
        expect(requests, hasLength(1));
        expect(result.warnings, isEmpty);
      });

      test('a term without its rendering is retried and reported', () async {
        stubAnswers(llmOf(plainOpenAi), [
          // (A rendering in a word counts: no "informática" here.)
          'El equipo de sistemas está listo hoy.',
          'El equipo de sistemas está listo hoy mismo.',
        ]);
        final result = await repository
            .translate(openAi, withIt('The IT team is ready today.'))
            .last;
        expect(requests, hasLength(2));
        expect(requests.last.messages.last.content, contains('glossary'));
        expect(
          result.warnings
              .singleWhere((w) => w.kind == TranslationWarningKind.glossary)
              .items,
          ['TI'],
        );
      });
    });

    test('a first attempt that fails is an error', () {
      stubAnswers(llmOf(plainOpenAi), [const LlmApiException('boom')]);
      expect(
        repository.translate(openAi, englishToGerman),
        emitsThrough(emitsError(isA<LlmApiException>())),
      );
    });

    group('temperature', () {
      const request = TranslationRequest(
        text: 'Hello',
        source: english,
        target: german,
      );

      Future<double?> temperatureFor(AiProviderConfig config) async {
        repository = newRepository(providers: [config]);
        stubAnswers(llmOf(plainOpenAi), ['Hallo']);
        await repository.translate(aiEngine(config), request).drain<void>();
        return requests.single.temperature;
      }

      test('defaults low for models known to accept it', () async {
        expect(
          await temperatureFor(plainOpenAi),
          TranslationRepository.defaultAiTemperature,
        );
        expect(
          await temperatureFor(plainOpenAi.copyWith(temperature: 0.7)),
          0.7,
        );
      });

      test('is left out for reasoning models and with an effort', () async {
        for (final model in [
          'o3-mini',
          'openai/o1',
          'gpt-5',
          'deepseek-reasoner',
          'deepseek/deepseek-r1:free',
          'qwq-32b',
          'gemini-2.0-flash-thinking-exp',
        ]) {
          expect(
            await temperatureFor(plainOpenAi.copyWith(model: model)),
            isNull,
            reason: model,
          );
        }
        expect(
          await temperatureFor(plainOpenAi.copyWith(effort: 'low')),
          isNull,
        );
      });

      test('is never sent to Anthropic', () async {
        stubAnswers(llmOf(claudeConfig), ['Hallo']);
        await repository.translate(claude, request).drain<void>();
        expect(requests.single.temperature, isNull);
      });

      test('is dropped after a 400, for the session', () async {
        stubAnswers(llmOf(plainOpenAi), [
          const LlmApiException('temperature unsupported', statusCode: 400),
          'Hallo',
          'Hallo Welt',
        ]);
        final result = await repository.translate(openAi, request).last;
        expect(result.text, 'Hallo');
        expect(requests.map((r) => r.temperature), [
          TranslationRepository.defaultAiTemperature,
          null,
        ]);
        await repository
            .translate(openAi, request.copyWith(text: 'Hello world'))
            .drain<void>();
        expect(requests.last.temperature, isNull);
      });

      test('other errors are not retried', () async {
        stubAnswers(llmOf(plainOpenAi), [
          const LlmApiException('rate limited', statusCode: 429),
        ]);
        await expectLater(
          repository.translate(openAi, request),
          emitsThrough(emitsError(isA<LlmApiException>())),
        );
        expect(requests, hasLength(1));
      });
    });

    group('long input', () {
      final paragraphs = [
        'Write to jane@x.org about the plan.',
        'Then call +49 30 1234567 about it.',
      ];
      final long = TranslationRequest(
        text: paragraphs.join('\n\n'),
        source: english,
        target: german,
      );

      void stubParts() {
        requests.clear();
        when(() => llmOf(plainOpenAi).streamChat(any())).thenAnswer((
          invocation,
        ) {
          final request = invocation.positionalArguments.single as LlmRequest;
          requests.add(request);
          return Stream.value('DE ${sourceOf(request)}');
        });
      }

      test('restores the personal data of every part', () async {
        repository = newRepository(aiChunkThreshold: 40);
        stubParts();
        final result = await repository.translate(openAi, long).last;
        expect(requests.map(sourceOf), [
          'Write to ⟨1⟩ about the plan.',
          'Then call ⟨2⟩ about it.',
        ]);
        expect(result.text, paragraphs.map((p) => 'DE $p').join('\n\n'));
        expect(result.maskedPersonalData, 2);
        expect(result.warnings, isEmpty);
      });

      test('parts come from the part cache unless refreshed', () async {
        repository = newRepository(aiChunkThreshold: 40);
        stubParts();
        await repository.translate(openAi, long).drain<void>();
        expect(requests, hasLength(2));
        // Only the changed part goes again.
        final edited = long.copyWith(
          text: '${paragraphs[0]}\n\nThen call us about it soon.',
        );
        await repository.translate(openAi, edited).drain<void>();
        expect(requests, hasLength(3));
        // Regenerate sends every part.
        await repository.translate(openAi, edited, refresh: true).drain<void>();
        expect(requests, hasLength(5));
        // So does a cleared cache.
        repository.clearCache();
        await repository.translate(openAi, edited).drain<void>();
        expect(requests, hasLength(7));
      });
    });

    test('refine masks personal data of both texts', () async {
      stubAnswers(llmOf(plainOpenAi), ['Schreiben Sie an ⟨1⟩.']);
      final result = await repository
          .refine(
            openAi,
            const TranslationRequest(
              text: 'Write to jane@x.org.',
              source: english,
              target: german,
            ),
            currentTranslation: 'Schreib an jane@x.org.',
            instruction: 'More formal',
          )
          .last;
      final prompt = requests.single.messages.map((m) => m.content).join();
      expect(prompt, isNot(contains('jane@x.org')));
      expect(prompt, contains('⟨1⟩'));
      expect(result.text, 'Schreiben Sie an jane@x.org.');
      expect(result.maskedPersonalData, 1);
    });
  });

  group('detection hint, on the device first', () {
    final claude = aiEngine(claudeConfig);
    const short = TranslationRequest(
      text: 'Gift',
      source: Language.auto,
      target: french,
    );
    final requests = <LlmRequest>[];

    void stubHint({
      String json = '{"language": "en"}',
      List<String> translation = const ['[[lang:en]]\n', 'Cadeau'],
    }) {
      requests.clear();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((invocation) {
            final request = invocation.positionalArguments.single as LlmRequest;
            requests.add(request);
            return request.jsonOutput
                ? Stream.value(json)
                : Stream.fromIterable(translation);
          });
    }

    List<LlmRequest> detections() =>
        requests.where((request) => request.jsonOutput).toList();

    test('no model detection when the device agrees', () async {
      repository = newRepository(
        device: FakeOfflineTranslator(identified: 'en'),
      );
      stubHint();
      final result = await repository.translate(claude, short).last;
      expect(result.detectedSource, 'en');
      expect(result.detectionUncertain, isFalse);
      expect(detections(), isEmpty);
      // The verdict is cached.
      final cached = await repository.translate(claude, short).single;
      expect(cached.fromCache, isTrue);
    });

    test('asks the model when the device is unsure', () async {
      repository = newRepository(device: FakeOfflineTranslator());
      stubHint(json: '{"language": "de"}');
      final result = await repository.translate(claude, short).last;
      expect(detections(), hasLength(1));
      expect(result.detectionUncertain, isTrue);
    });

    test('asks the model when the device disagrees', () async {
      repository = newRepository(
        device: FakeOfflineTranslator(identified: 'de'),
      );
      stubHint();
      final result = await repository.translate(claude, short).last;
      expect(detections(), hasLength(1));
      expect(result.detectionUncertain, isFalse);
    });

    test('keeps the device doubt when the model does not answer', () async {
      repository = newRepository(
        device: FakeOfflineTranslator(identified: 'de'),
      );
      requests.clear();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((invocation) {
            final request = invocation.positionalArguments.single as LlmRequest;
            requests.add(request);
            return request.jsonOutput
                ? Stream.error(const LlmApiException('boom'))
                : Stream.fromIterable(const ['[[lang:en]]\n', 'Cadeau']);
          });
      final result = await repository.translate(claude, short).last;
      expect(result.detectionUncertain, isTrue);
      expect(result.detectedAlternatives, ['de']);
      final again = await repository.translate(claude, short).last;
      expect(again.fromCache, isFalse);
    });

    test('waits for a slow device answer, then decides', () async {
      for (final (code, asked) in [('en', 0), ('de', 1)]) {
        final device = _SlowIdentifier();
        repository = newRepository(device: device);
        stubHint();
        final results = repository.translate(claude, short).toList();
        await pumpEventQueue();
        // The translation is done; the final result waits for the device.
        expect(requests.where((r) => !r.jsonOutput), hasLength(1));
        device.answer.complete(code);
        final last = (await results).last;
        expect(last.isComplete, isTrue);
        expect(detections(), hasLength(asked), reason: code);
      }
    });

    test('a slow device that is unsure asks the model', () async {
      final device = _SlowIdentifier();
      repository = newRepository(device: device);
      stubHint(translation: const ['Cadeau']);
      final results = repository.translate(claude, short).toList();
      await pumpEventQueue();
      device.answer.complete(null);
      await results;
      expect(detections(), hasLength(1));
    });

    test('an identifier error asks the model', () async {
      repository = newRepository(device: _ThrowingIdentifier());
      stubHint();
      await repository.translate(claude, short).drain<void>();
      expect(detections(), hasLength(1));
    });

    test('masks personal data in the detection', () async {
      repository = newRepository(device: FakeOfflineTranslator());
      stubHint();
      await repository
          .translate(claude, short.copyWith(text: 'jane@x.org'))
          .drain<void>();
      expect(
        detections().single.messages.last.content,
        isNot(contains('jane@x.org')),
      );
    });
  });

  group('warmUp', () {
    final local = aiEngine(ollamaConfig);

    test('warms the model of local AI engines up', () async {
      when(() => llmOf(ollamaConfig).warmUp(any()))
          .thenAnswer((_) async => true);
      expect(await repository.warmUp(local), isTrue);
      verify(() => llmOf(ollamaConfig).warmUp('qwen3')).called(1);
    });

    test('engines marked local count as local', () async {
      when(() => llmOf(plainOpenAi).warmUp(any()))
          .thenAnswer((_) async => true);
      const marked = TranslationEngine(
        id: 'ai:openai',
        kind: EngineKind.ai,
        name: 'OpenAI',
        providerId: 'openai',
        isLocal: true,
      );
      expect(await repository.warmUp(marked), isTrue);
    });

    test('does nothing for other engines and in offline-only mode', () async {
      expect(await repository.warmUp(aiEngine(plainOpenAi)), isFalse);
      expect(await repository.warmUp(googleEngine), isFalse);
      expect(
        await repository.warmUp(
          aiEngine(ollamaConfig.copyWith(name: 'x')).withProvider('gone'),
        ),
        isFalse,
      );
      repository.updatePrivacy(mode: PrivacyMode.offlineOnly);
      expect(await repository.warmUp(local), isFalse);
      verifyNever(() => llmOf(plainOpenAi).warmUp(any()));
      verifyNever(() => llmOf(ollamaConfig).warmUp(any()));
    });

    test('a failure is false', () async {
      when(() => llmOf(ollamaConfig).warmUp(any()))
          .thenThrow(const LlmApiException('down'));
      expect(await repository.warmUp(local), isFalse);
    });
  });

  group('needsConsent', () {
    test('follows the privacy settings without using anything up', () {
      repository.updatePrivacy(mode: PrivacyMode.offlineFirst);
      expect(
        repository.needsConsent(googleEngine, source: english, target: german),
        isTrue,
      );
      expect(
        repository.needsConsent(
          TranslationEngine.offline(),
          source: english,
          target: german,
        ),
        isFalse,
      );
      repository.updatePrivacy(
        mode: PrivacyMode.offlineFirst,
        approvedPairs: [TranslationRepository.pairKey('en', 'de')],
        consentedProviders: const ['deepl'],
      );
      expect(
        repository.needsConsent(googleEngine, source: english, target: german),
        isFalse,
      );
      // A probe does not unlock the lists.
      expect(repository.metadataDeferred, isTrue);
      expect(
        repository.needsConsent(
          mtEngine(deeplConfig),
          source: english,
          target: german,
        ),
        isFalse,
      );
      expect(
        repository.needsConsent(
          aiEngine(claudeConfig),
          source: english,
          target: german,
        ),
        isTrue,
      );
      // A local provider only needs the approved pair.
      expect(
        repository.needsConsent(
          aiEngine(ollamaConfig),
          source: english,
          target: german,
        ),
        isFalse,
      );
      // An engine whose provider is gone cannot be used.
      expect(
        repository.needsConsent(
          aiEngine(ollamaConfig).withProvider('gone'),
          source: english,
          target: german,
        ),
        isTrue,
      );
    });
  });

  test('detectLanguage masks personal data for Mozhi', () async {
    whenMozhi().thenAnswer((invocation) async {
      sentToMozhi.add(invocation.namedArguments[#text] as String);
      return const MozhiTranslation(
        engine: 'google',
        translatedText: 'x',
        detectedLanguage: 'de',
      );
    });
    sentToMozhi.clear();
    final detected = await repository.detectLanguage('Schreib an a@b.de');
    expect(detected.code, 'de');
    expect(sentToMozhi.single, 'Schreib an ⟨1⟩');
  });

  test('detectLanguage masks personal data for AI engines', () async {
    when(() => llmOf(claudeConfig).chat(any()))
        .thenAnswer((_) async => '{"language": "de"}');
    await repository.detectLanguage(
      'Schreib an a@b.de',
      engine: aiEngine(claudeConfig),
    );
    final request =
        verify(() => llmOf(claudeConfig).chat(captureAny())).captured.single
            as LlmRequest;
    expect(request.messages.last.content, isNot(contains('a@b.de')));
  });
}

extension on TranslationEngine {
  TranslationEngine withProvider(String providerId) => TranslationEngine(
    id: 'ai:$providerId',
    kind: kind,
    name: name,
    providerId: providerId,
    isLocal: isLocal,
  );

  TranslationEngine copyWithId(String id) => TranslationEngine(
    id: id,
    kind: kind,
    name: name,
    providerId: id.substring(3),
    mtService: mtService,
  );
}

/// An identifier that answers when [answer] completes.
class _SlowIdentifier extends FakeOfflineTranslator {
  final answer = Completer<String?>();

  @override
  Future<String?> identifyLanguage(String text) => answer.future;
}

/// An identifier that fails.
class _ThrowingIdentifier extends FakeOfflineTranslator {
  @override
  Future<String?> identifyLanguage(String text) =>
      Future.error(StateError('no'));
}
