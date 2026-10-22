import 'dart:async';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  late Map<String, MockLlmClient> llm;
  late MockMozhiApiClient mozhi;
  late TranslationCache cache;
  late TranslationRepository repository;

  MockLlmClient llmOf(AiProviderConfig config) =>
      llm[Uri.parse(config.baseUrl).host]!;

  TranslationRepository newRepository({
    int aiChunkThreshold = TranslationRepository.defaultAiChunkThreshold,
    int localAiChunkThreshold =
        TranslationRepository.defaultLocalAiChunkThreshold,
    Duration detectionHintTimeout =
        TranslationRepository.defaultDetectionHintTimeout,
  }) {
    final repository =
        TranslationRepository(
          mozhiClientFactory: (_) => mozhi,
          llmClientFactory: (endpoint) => llm[endpoint.baseUrl.host]!,
          cache: cache,
          snapshotInterval: Duration.zero,
          aiChunkThreshold: aiChunkThreshold,
          localAiChunkThreshold: localAiChunkThreshold,
          detectionHintTimeout: detectionHintTimeout,
        )..updateConfiguration(
          instances: const [instanceA],
          providers: const [
            claudeConfig,
            openAiConfig,
            ollamaConfig,
            cloudGemmaConfig,
          ],
        );
    allowNetwork(repository);
    addTearDown(repository.dispose);
    return repository;
  }

  setUp(() {
    llm = {
      for (final config in [
        claudeConfig,
        openAiConfig,
        ollamaConfig,
        cloudGemmaConfig,
      ])
        Uri.parse(config.baseUrl).host: MockLlmClient(),
    };
    mozhi = MockMozhiApiClient();
    cache = TranslationCache();
    repository = newRepository();
  });

  /// Answers every streamed chat with [answer] of its request.
  void stubStreams(
    MockLlmClient client,
    List<String> Function(LlmRequest request) answer,
  ) => when(() => client.streamChat(any())).thenAnswer(
    (invocation) => Stream.fromIterable(
      answer(invocation.positionalArguments.single as LlmRequest),
    ),
  );

  void stubStream(MockLlmClient client, List<String> deltas) =>
      stubStreams(client, (_) => deltas);

  /// Mozhi google detects [code] (used by translation-specialised models).
  void stubDetection(String code) =>
      when(
        () => mozhi.translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      ).thenAnswer(
        (_) async => MozhiTranslation(
          engine: 'google',
          translatedText: 'x',
          detectedLanguage: code,
        ),
      );

  List<LlmRequest> streamed(MockLlmClient client) =>
      verify(() => client.streamChat(captureAny())).captured.cast<LlmRequest>();

  /// The `<source>` text of a translation request.
  String sourceOf(LlmRequest request) {
    final user = request.messages.last.content;
    return RegExp(r'<source>\n([\s\S]*)\n</source>').firstMatch(user)![1]!;
  }

  final claude = aiEngine(claudeConfig);
  final ollama = aiEngine(ollamaConfig);
  final cloudGemma = aiEngine(cloudGemmaConfig);
  const autoToGerman = TranslationRequest(
    text: 'Good morning to all of you',
    source: Language.auto,
    target: german,
  );
  const englishToGerman = TranslationRequest(
    text: 'Good morning',
    source: english,
    target: german,
  );

  group('constructor', () {
    test('has default chunk thresholds and detection timeout', () {
      expect(TranslationRepository.defaultAiChunkThreshold, 6000);
      expect(TranslationRepository.defaultLocalAiChunkThreshold, 2500);
      expect(
        TranslationRepository.defaultDetectionHintTimeout,
        const Duration(seconds: 2),
      );
    });

    test('rejects chunk thresholds below 1', () {
      expect(
        () => TranslationRepository(aiChunkThreshold: 0),
        throwsRangeError,
      );
      expect(
        () => TranslationRepository(localAiChunkThreshold: 0),
        throwsRangeError,
      );
    });
  });

  group('fromCache', () {
    test('is false for fresh and true for cached AI results', () async {
      stubStream(llmOf(claudeConfig), ['Guten ', 'Morgen']);
      final fresh = await repository
          .translate(claude, englishToGerman)
          .toList();
      expect(fresh.map((r) => r.fromCache), everyElement(isFalse));
      final cached = await repository
          .translate(claude, englishToGerman)
          .toList();
      expect(cached.single.fromCache, isTrue);
      expect(cached.single.text, 'Guten Morgen');
      expect(cached.single, fresh.last.copyWith(fromCache: true));
      verify(() => llmOf(claudeConfig).streamChat(any())).called(1);
    });

    test('is true for cached Mozhi results', () async {
      when(
        () => mozhi.translate(
          engine: any(named: 'engine'),
          from: any(named: 'from'),
          to: any(named: 'to'),
          text: any(named: 'text'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      ).thenAnswer(
        (_) async =>
            const MozhiTranslation(engine: 'google', translatedText: 'Hallo'),
      );
      final first = await repository
          .translate(googleEngine, englishToGerman)
          .single;
      final second = await repository
          .translate(googleEngine, englishToGerman)
          .single;
      expect(first.fromCache, isFalse);
      expect(second.fromCache, isTrue);
    });

    test('is false again after a refresh', () async {
      stubStream(llmOf(claudeConfig), ['Hallo']);
      await repository.translate(claude, englishToGerman).drain<void>();
      final refreshed = await repository
          .translate(claude, englishToGerman, refresh: true)
          .last;
      expect(refreshed.fromCache, isFalse);
    });
  });

  group('long input', () {
    const paragraphs = [
      'The first paragraph is here.',
      'The second paragraph follows it.',
      'And this is the third paragraph.',
    ];
    final longText = paragraphs.join('\n\n');
    final longRequest = TranslationRequest(
      text: longText,
      source: english,
      target: german,
      options: const TranslationOptions(context: 'A novel'),
    );

    /// A fake German translation of a part (not an echo of it).
    String fakeGerman(String text) => 'DE ${text.toUpperCase()}';

    String upper(LlmRequest request) => fakeGerman(sourceOf(request));

    test('is translated in parts and joined with the separators', () async {
      repository = newRepository(aiChunkThreshold: 40);
      stubStreams(llmOf(claudeConfig), (request) => [upper(request)]);
      final results = await repository.translate(claude, longRequest).toList();
      expect(results.last.isComplete, isTrue);
      expect(results.where((r) => r.isComplete), hasLength(1));
      expect(
        results.last.text,
        paragraphs.map(fakeGerman).join('\n\n'),
      );
      expect(results.last.engineId, 'ai:claude');

      final requests = streamed(llmOf(claudeConfig));
      expect(requests.map(sourceOf), paragraphs);
      expect(
        requests[0].messages,
        TranslationPrompts.translate(longRequest.copyWith(text: paragraphs[0])),
      );
      expect(
        requests[1].messages,
        TranslationPrompts.translate(
          longRequest.copyWith(text: paragraphs[1]),
          precedingText: paragraphs[0],
        ),
      );
      // The preceding part and the context are data in the user message;
      // the system prompt only refers to them.
      expect(
        requests[2].messages.last.content,
        '<context>\nA novel\n</context>\n'
        '<preceding_text>\n${paragraphs[1]}\n</preceding_text>\n'
        '<source>\n${paragraphs[2]}\n</source>',
      );
      expect(
        requests[2].messages.first.content,
        isNot(contains(paragraphs[1])),
      );
      expect(
        requests[2].messages.first.content,
        allOf(isNot(contains('A novel')), contains('in <context> tags')),
      );
    });

    test('caches only the combined result', () async {
      repository = newRepository(aiChunkThreshold: 40);
      stubStreams(llmOf(claudeConfig), (request) => [upper(request)]);
      final translated = await repository.translate(claude, longRequest).last;
      expect(cache.length, 1);
      for (final paragraph in paragraphs) {
        expect(
          cache.contains(claude, longRequest.copyWith(text: paragraph)),
          isFalse,
        );
      }
      final cached = await repository.translate(claude, longRequest).single;
      expect(cached, translated.copyWith(fromCache: true));
      verify(() => llmOf(claudeConfig).streamChat(any())).called(3);
    });

    test('is not split below the threshold', () async {
      stubStream(llmOf(claudeConfig), ['Der ganze Text, auf Deutsch.']);
      await repository.translate(claude, longRequest).drain<void>();
      expect(streamed(llmOf(claudeConfig)).map(sourceOf), [longText]);
    });

    test('uses the smaller threshold for local providers', () async {
      repository = newRepository(
        aiChunkThreshold: 1000,
        localAiChunkThreshold: 40,
      );
      stubStreams(llmOf(ollamaConfig), (request) => [upper(request)]);
      stubStreams(llmOf(claudeConfig), (request) => [upper(request)]);
      await repository.translate(ollama, longRequest).drain<void>();
      await repository.translate(claude, longRequest).drain<void>();
      expect(streamed(llmOf(ollamaConfig)), hasLength(3));
      expect(streamed(llmOf(claudeConfig)), hasLength(1));
    });

    test('treats engines marked local as local', () async {
      repository = newRepository(
        aiChunkThreshold: 1000,
        localAiChunkThreshold: 40,
      );
      stubStreams(llmOf(claudeConfig), (request) => [upper(request)]);
      final local = TranslationEngine(
        id: claude.id,
        kind: EngineKind.ai,
        name: claude.name,
        providerId: claude.providerId,
        isLocal: true,
      );
      await repository.translate(local, longRequest).drain<void>();
      expect(streamed(llmOf(claudeConfig)), hasLength(3));
    });

    test('is not split when no chunk boundary exists', () async {
      repository = newRepository(aiChunkThreshold: 10);
      stubStream(llmOf(claudeConfig), ['Code']);
      const code = '```\nint a = 1;\n\nint b = 2;\n```';
      await repository
          .translate(claude, longRequest.copyWith(text: code))
          .drain<void>();
      expect(streamed(llmOf(claudeConfig)).map(sourceOf), [code]);
    });

    test('pins the source detected by the first part', () async {
      repository = newRepository(aiChunkThreshold: 40);
      stubStreams(
        llmOf(claudeConfig),
        (request) => [
          if (request.messages.first.content.contains('[[lang:'))
            '[[lang:en]]\n',
          upper(request),
        ],
      );
      final auto = longRequest.copyWith(source: Language.auto);
      final results = await repository.translate(claude, auto).toList();
      expect(results.map((r) => r.detectedSource), everyElement('en'));
      expect(
        results.last.text,
        paragraphs.map(fakeGerman).join('\n\n'),
      );
      final requests = streamed(llmOf(claudeConfig));
      final pinned = LanguageCatalog.byCode('en')!;
      expect(
        requests[1].messages,
        TranslationPrompts.translate(
          auto.copyWith(text: paragraphs[1], source: pinned),
          precedingText: paragraphs[0],
        ),
      );
    });

    test(
      'keeps later parts auto when the first is in the target language',
      () async {
        // An English e-mail with a German reply, translated into English: the
        // reply must not be sent as English -> English ("do not translate").
        repository = newRepository(aiChunkThreshold: 40);
        stubStreams(
          llmOf(claudeConfig),
          (request) => [
            if (request.messages.first.content.contains('[[lang:'))
              '[[lang:en]]\n',
            upper(request),
          ],
        );
        final toEnglish = longRequest.copyWith(
          source: Language.auto,
          target: english,
        );
        final results = await repository.translate(claude, toEnglish).toList();
        expect(results.last.isComplete, isTrue);
        expect(results.last.detectedSource, 'en');
        final requests = streamed(llmOf(claudeConfig));
        expect(requests, hasLength(3));
        for (final request in requests.skip(1)) {
          final system = request.messages.first.content;
          expect(system, contains('Source language: detect it.'));
          expect(system, isNot(contains('is already in English, so do not')));
        }
        expect(
          requests[1].messages,
          TranslationPrompts.translate(
            toEnglish.copyWith(text: paragraphs[1]),
            precedingText: paragraphs[0],
          ),
        );
      },
    );

    test('reports the detected language before the first part ends', () async {
      repository = newRepository(aiChunkThreshold: 40);
      final first = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => first.stream);
      final results = <TranslationResult>[];
      final subscription = repository
          .translate(claude, longRequest.copyWith(source: Language.auto))
          .listen(results.add);
      await pumpEventQueue();
      first.controller.add('[[lang:en]]\n');
      await pumpEventQueue();
      expect(results.single.detectedSource, 'en');
      expect(results.single.text, isEmpty);
      expect(results.single.isComplete, isFalse);
      await subscription.cancel();
      expect(first.cancelled, isTrue);
    });

    test('emits the error of a part and cancels the others', () async {
      repository = newRepository(aiChunkThreshold: 40);
      final slow = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((invocation) {
            final request = invocation.positionalArguments.single as LlmRequest;
            return sourceOf(request) == paragraphs[0]
                ? slow.stream
                : Stream.error(const LlmApiException('overloaded'));
          });
      await expectLater(
        repository.translate(claude, longRequest),
        emitsThrough(emitsError(isA<LlmApiException>())),
      );
      expect(slow.cancelled, isTrue);
      expect(cache.isEmpty, isTrue);
    });

    test('splits translation-specialised models too', () async {
      repository = newRepository(aiChunkThreshold: 40);
      stubStreams(llmOf(cloudGemmaConfig), (request) {
        final text = request.messages.last.content;
        return [paragraphs.firstWhere(text.contains).toUpperCase()];
      });
      final results = await repository
          .translate(cloudGemma, longRequest)
          .toList();
      expect(
        results.last.text,
        paragraphs.map((p) => p.toUpperCase()).join('\n\n'),
      );
      final requests = streamed(llmOf(cloudGemmaConfig));
      expect(requests, hasLength(3));
      final profile = cloudGemmaConfig.resolvedPromptProfile;
      expect(
        requests[0].messages,
        MtPrompts.translate(profile, longRequest.copyWith(text: paragraphs[0])),
      );
    });

    test('splits translation-specialised models after detection', () async {
      repository = newRepository(aiChunkThreshold: 40);
      stubDetection('en');
      stubStream(llmOf(cloudGemmaConfig), ['TEIL']);
      final results = await repository
          .translate(cloudGemma, longRequest.copyWith(source: Language.auto))
          .toList();
      expect(results.map((r) => r.detectedSource), everyElement('en'));
      expect(results.last.text, 'TEIL\n\nTEIL\n\nTEIL');
    });
  });

  group('early detected language', () {
    test('partial snapshots carry the marker language at once', () async {
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => deltas.stream);
      final results = <TranslationResult>[];
      final subscription = repository
          .translate(claude, autoToGerman)
          .listen(results.add);
      await pumpEventQueue();
      deltas.controller.add('[[lang:');
      await pumpEventQueue();
      expect(results, isEmpty);
      deltas.controller.add('de]]');
      await pumpEventQueue();
      expect(results.single.detectedSource, 'de');
      expect(results.single.text, isEmpty);
      expect(results.single.isComplete, isFalse);
      // The caller can stop as soon as the source equals the target.
      await subscription.cancel();
      expect(deltas.cancelled, isTrue);
    });
  });

  group('detection hint', () {
    const short = TranslationRequest(
      text: 'Gift',
      source: Language.auto,
      target: french,
    );

    /// Answers the streamed translation with [translation] and the
    /// detection (a streamed JSON request) with [detection].
    void stubHint(
      MockLlmClient client, {
      List<String> translation = const ['[[lang:en]]\n', 'Cadeau'],
      Stream<String> Function()? detection,
      String json = '{"language": "en"}',
    }) => when(() => client.streamChat(any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments.single as LlmRequest;
      if (!request.jsonOutput) return Stream.fromIterable(translation);
      return detection?.call() ?? Stream.fromIterable([json]);
    });

    /// The streamed detection requests.
    List<LlmRequest> detections(MockLlmClient client) =>
        streamed(client).where((r) => r.jsonOutput).toList();

    void verifyNoDetection(MockLlmClient client) {
      verifyNever(
        () => client.streamChat(
          any(
            that: isA<LlmRequest>().having(
              (r) => r.jsonOutput,
              'jsonOutput',
              isTrue,
            ),
          ),
        ),
      );
      verifyNever(() => client.chat(any()));
    }

    test('marks a disagreeing detection as uncertain', () async {
      stubHint(
        llmOf(claudeConfig),
        json:
            '{"language": "de", "uncertain": false, '
            '"alternatives": ["en", "nl"]}',
      );
      final results = await repository.translate(claude, short).toList();
      final last = results.last;
      expect(last.isComplete, isTrue);
      expect(last.text, 'Cadeau');
      expect(last.detectedSource, 'en');
      expect(last.detectionUncertain, isTrue);
      expect(last.detectedAlternatives, ['de', 'nl']);
      expect(results.where((r) => r.isComplete), hasLength(1));
      expect(
        results.where((r) => !r.isComplete),
        everyElement(
          isA<TranslationResult>().having(
            (r) => r.detectionUncertain,
            'detectionUncertain',
            isFalse,
          ),
        ),
      );
      final detection = detections(llmOf(claudeConfig)).single;
      expect(detection.messages, TranslationPrompts.detectLanguage('Gift'));
      expect(detection.jsonOutput, isTrue);
      verifyNever(() => llmOf(claudeConfig).chat(any()));
    });

    test('sends the detection without reasoning effort', () async {
      // A high reasoning effort would make the best-effort check slower
      // than the translation of a word or two.
      stubHint(llmOf(claudeConfig));
      stubHint(llmOf(openAiConfig));
      await repository.translate(claude, short).drain<void>();
      await repository.translate(aiEngine(openAiConfig), short).drain<void>();
      final requests = streamed(llmOf(claudeConfig));
      final anthropic = requests.where((r) => r.jsonOutput).single;
      expect(anthropic.effort, isNull);
      expect(anthropic.temperature, isNull);
      expect(anthropic.model, claudeConfig.model);
      // The translation keeps the provider's effort.
      expect(requests.where((r) => !r.jsonOutput).single.effort, 'low');
      final openAi = detections(llmOf(openAiConfig)).single;
      expect(openAi.effort, isNull);
      expect(openAi.temperature, openAiConfig.temperature);
    });

    test('is not retried after invalid JSON', () async {
      stubHint(llmOf(claudeConfig), json: '???');
      final result = await repository.translate(claude, short).last;
      expect(result.isComplete, isTrue);
      expect(result.text, 'Cadeau');
      expect(result.detectionUncertain, isFalse);
      expect(detections(llmOf(claudeConfig)), hasLength(1));
    });

    test('prefers recent source languages', () async {
      stubHint(
        llmOf(claudeConfig),
        json:
            '{"language": "en", "uncertain": true, '
            '"alternatives": ["de", "sv", "nl", "da"]}',
      );
      final result = await repository
          .translate(
            claude,
            short.copyWith(recentSourceLanguages: ['fr', 'nl', 'da']),
          )
          .last;
      expect(result.detectionUncertain, isTrue);
      expect(result.detectedAlternatives, ['nl', 'da', 'de']);
    });

    test('marks a detection that names alternatives', () async {
      stubHint(
        llmOf(claudeConfig),
        json: '{"language": "en-GB", "alternatives": ["en", "de"]}',
      );
      final result = await repository.translate(claude, short).last;
      expect(result.detectionUncertain, isTrue);
      expect(result.detectedAlternatives, ['de']);
    });

    test('leaves a confirmed detection alone', () async {
      stubHint(
        llmOf(claudeConfig),
        json:
            '{"language": "en-US", "uncertain": false, "alternatives": ["en"]}',
      );
      final result = await repository.translate(claude, short).last;
      expect(result.detectionUncertain, isFalse);
      expect(result.detectedAlternatives, isEmpty);
    });

    test('suggests the detection when the model gave no marker', () async {
      stubHint(
        llmOf(claudeConfig),
        translation: ['Cadeau'],
        json: '{"language": "de", "uncertain": true, "alternatives": ["en"]}',
      );
      final result = await repository.translate(claude, short).last;
      expect(result.detectedSource, isNull);
      expect(result.detectionUncertain, isTrue);
      expect(result.detectedAlternatives, ['de', 'en']);
    });

    test('ignores a confident detection when there is no marker', () async {
      stubHint(
        llmOf(claudeConfig),
        translation: ['Cadeau'],
        json: '{"language": "de"}',
      );
      final result = await repository.translate(claude, short).last;
      expect(result.detectionUncertain, isFalse);
    });

    test('ignores detection errors', () async {
      stubHint(
        llmOf(claudeConfig),
        detection: () => Stream.error(const LlmApiException('quota')),
      );
      final results = await repository.translate(claude, short).toList();
      expect(results.last.isComplete, isTrue);
      expect(results.last.text, 'Cadeau');
      expect(results.last.detectionUncertain, isFalse);
    });

    test('ignores a detection request that cannot be made', () async {
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((invocation) {
            final request = invocation.positionalArguments.single as LlmRequest;
            if (request.jsonOutput) throw StateError('closed');
            return Stream.fromIterable(['[[lang:en]]\n', 'Cadeau']);
          });
      final result = await repository.translate(claude, short).last;
      expect(result.isComplete, isTrue);
      expect(result.detectionUncertain, isFalse);
    });

    test('is cached with the result', () async {
      stubHint(
        llmOf(claudeConfig),
        json: '{"language": "de", "uncertain": true}',
      );
      await repository.translate(claude, short).drain<void>();
      final cached = await repository.translate(claude, short).single;
      expect(cached.fromCache, isTrue);
      expect(cached.detectionUncertain, isTrue);
      expect(cached.detectedAlternatives, ['de']);
      expect(detections(llmOf(claudeConfig)), hasLength(1));
    });

    test('caches a confirmed detection too', () async {
      stubHint(llmOf(claudeConfig));
      await repository.translate(claude, short).drain<void>();
      final cached = await repository.translate(claude, short).single;
      expect(cached.fromCache, isTrue);
      expect(cached.detectionUncertain, isFalse);
    });

    test('waits for a slower detection without holding the text', () async {
      final detection = ControlledDeltas();
      stubHint(
        llmOf(claudeConfig),
        translation: ['[[lang:en]]\n', 'Cad', 'eau '],
        detection: () => detection.stream,
      );
      final results = <TranslationResult>[];
      final done = Completer<void>();
      repository
          .translate(claude, short)
          .listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      // The cleaned final text is shown as a partial snapshot.
      expect(results.last.text, 'Cadeau');
      expect(results.last.isComplete, isFalse);
      expect(results.where((r) => r.isComplete), isEmpty);

      detection.controller
        ..add('{"language": "de", ')
        ..add('"uncertain": true}');
      await detection.controller.close();
      await done.future;
      expect(results.last.isComplete, isTrue);
      expect(results.last.text, 'Cadeau');
      expect(results.last.detectionUncertain, isTrue);
    });

    test('does not repeat a final text the last snapshot showed', () async {
      final detection = ControlledDeltas();
      stubHint(
        llmOf(claudeConfig),
        translation: ['[[lang:en]]\nCadeau'],
        detection: () => detection.stream,
      );
      final results = <TranslationResult>[];
      final done = Completer<void>();
      repository
          .translate(claude, short)
          .listen(results.add, onDone: done.complete);
      await pumpEventQueue();
      detection.controller.add('{"language": "en"}');
      await detection.controller.close();
      await done.future;
      expect(results.map((r) => (r.text, r.isComplete)), [
        ('Cadeau', false),
        ('Cadeau', true),
      ]);
    });

    test(
      'gives up waiting after the timeout and aborts the detection',
      () async {
        repository = newRepository(
          detectionHintTimeout: const Duration(milliseconds: 10),
        );
        final detection = ControlledDeltas();
        stubHint(llmOf(claudeConfig), detection: () => detection.stream);
        final result = await repository.translate(claude, short).last;
        expect(result.isComplete, isTrue);
        expect(result.detectionUncertain, isFalse);
        expect(detection.cancelled, isTrue);
        // A result without the verdict is not cached: the next translation
        // runs the check again.
        expect(cache.isEmpty, isTrue);
        final again = ControlledDeltas();
        stubHint(llmOf(claudeConfig), detection: () => again.stream);
        final second = await repository.translate(claude, short).last;
        expect(second.fromCache, isFalse);
        expect(again.cancelled, isTrue);
      },
    );

    test('does not cache a result whose detection failed', () async {
      stubHint(
        llmOf(claudeConfig),
        detection: () => Stream.error(const LlmApiException('quota')),
      );
      await repository.translate(claude, short).drain<void>();
      expect(cache.isEmpty, isTrue);
    });

    test('stops waiting and aborts the detection when cancelled', () async {
      final detection = ControlledDeltas();
      stubHint(llmOf(claudeConfig), detection: () => detection.stream);
      final results = <TranslationResult>[];
      final subscription = repository
          .translate(claude, short)
          .listen(results.add);
      await pumpEventQueue();
      expect(detection.cancelled, isFalse);
      await subscription.cancel();
      expect(detection.cancelled, isTrue);
      await pumpEventQueue();
      expect(results.where((r) => r.isComplete), isEmpty);
      expect(cache.isEmpty, isTrue);
    });

    test('aborts the detection when cancelled while translating', () async {
      final deltas = ControlledDeltas();
      final detection = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((invocation) {
            final request = invocation.positionalArguments.single as LlmRequest;
            return request.jsonOutput ? detection.stream : deltas.stream;
          });
      final subscription = repository.translate(claude, short).listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();
      expect(deltas.cancelled, isTrue);
      expect(detection.cancelled, isTrue);
    });

    test('forwards pause and resume', () async {
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((invocation) {
            final request = invocation.positionalArguments.single as LlmRequest;
            return request.jsonOutput
                ? Stream.fromIterable(['{"language": "en"}'])
                : deltas.stream;
          });
      final subscription = repository.translate(claude, short).listen((_) {});
      await pumpEventQueue();
      subscription.pause();
      expect(deltas.controller.isPaused, isTrue);
      subscription.resume();
      expect(deltas.controller.isPaused, isFalse);
      await subscription.cancel();
      expect(deltas.cancelled, isTrue);
    });

    test('forwards translation errors and aborts the detection', () async {
      final detection = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((invocation) {
            final request = invocation.positionalArguments.single as LlmRequest;
            return request.jsonOutput
                ? detection.stream
                : Stream.error(const LlmRefusalException('no'));
          });
      await expectLater(
        repository.translate(claude, short),
        emitsInOrder([emitsError(isA<LlmRefusalException>()), emitsDone]),
      );
      expect(detection.cancelled, isTrue);
    });

    group('and the cache', () {
      test('keys short input by the recent source languages', () async {
        stubHint(
          llmOf(claudeConfig),
          json: '{"language": "de", "uncertain": true}',
        );
        final recentGerman = short.copyWith(recentSourceLanguages: ['de']);
        await repository.translate(claude, recentGerman).drain<void>();
        // Other recent languages may change the reading of the text.
        final other = await repository
            .translate(claude, short.copyWith(recentSourceLanguages: ['en']))
            .last;
        expect(other.fromCache, isFalse);
        final same = await repository.translate(claude, recentGerman).single;
        expect(same.fromCache, isTrue);
        expect(
          streamed(llmOf(claudeConfig)).where((r) => !r.jsonOutput),
          hasLength(2),
        );
      });

      test('keys the prompt hint of 4 words by them too', () async {
        // Too long for the second detection, short for the prompt's hint.
        stubHint(llmOf(claudeConfig));
        final fourWords = short.copyWith(
          text: 'Gift for the kids',
          recentSourceLanguages: ['de'],
        );
        await repository.translate(claude, fourWords).drain<void>();
        final other = await repository
            .translate(
              claude,
              fourWords.copyWith(recentSourceLanguages: ['en']),
            )
            .last;
        expect(other.fromCache, isFalse);
        expect(
          (await repository.translate(claude, fourWords).single).fromCache,
          isTrue,
        );
      });

      test('ignores the recent source languages of long input', () async {
        // A plausible translation (one word would be a suspect result,
        // which is never cached).
        stubHint(
          llmOf(claudeConfig),
          translation: const [
            '[[lang:en]]\n',
            'Cette phrase est bien trop longue pour un indice de langue.',
          ],
        );
        for (final text in [
          'This sentence is far too long to need any language hint.',
          // One word of more than 64 characters.
          'Donaudampfschifffahrts' * 3,
        ]) {
          final long = short.copyWith(
            text: text,
            recentSourceLanguages: ['de'],
          );
          await repository.translate(claude, long).drain<void>();
          final cached = await repository
              .translate(claude, long.copyWith(recentSourceLanguages: ['en']))
              .single;
          expect(cached.fromCache, isTrue, reason: text);
        }
      });

      test('ignores the recent source languages of other engines', () async {
        when(
          () => mozhi.translate(
            engine: any(named: 'engine'),
            from: any(named: 'from'),
            to: any(named: 'to'),
            text: any(named: 'text'),
            abortTrigger: any(named: 'abortTrigger'),
          ),
        ).thenAnswer(
          (_) async => const MozhiTranslation(
            engine: 'google',
            translatedText: 'Cadeau',
          ),
        );
        await repository
            .translate(
              googleEngine,
              short.copyWith(recentSourceLanguages: ['de']),
            )
            .drain<void>();
        final cached = await repository
            .translate(
              googleEngine,
              short.copyWith(recentSourceLanguages: ['en']),
            )
            .single;
        expect(cached.fromCache, isTrue);
      });

      test('never takes a compare result for one with the hint', () async {
        stubHint(
          llmOf(claudeConfig),
          json: '{"language": "de", "uncertain": true}',
        );
        final compared = await repository.compare([claude], short).single;
        expect(compared.result!.detectionUncertain, isFalse);
        expect(cache.isEmpty, isTrue);
        final translated = await repository.translate(claude, short).last;
        expect(translated.fromCache, isFalse);
        expect(translated.detectionUncertain, isTrue);
      });

      test('serves compare mode a result with the hint', () async {
        stubHint(
          llmOf(claudeConfig),
          json: '{"language": "de", "uncertain": true}',
        );
        await repository.translate(claude, short).drain<void>();
        final compared = await repository.compare([claude], short).single;
        expect(compared.result!.fromCache, isTrue);
        expect(compared.result!.detectionUncertain, isTrue);
        expect(
          streamed(llmOf(claudeConfig)).where((r) => !r.jsonOutput),
          hasLength(1),
        );
      });

      test('is skipped on refresh', () async {
        stubHint(llmOf(claudeConfig));
        final recent = short.copyWith(recentSourceLanguages: ['de']);
        await repository.translate(claude, recent).drain<void>();
        final refreshed = await repository
            .translate(claude, recent, refresh: true)
            .last;
        expect(refreshed.fromCache, isFalse);
        expect(detections(llmOf(claudeConfig)), hasLength(2));
      });
    });

    group('is skipped', () {
      setUp(() {
        stubHint(
          llmOf(claudeConfig),
          json: '{"language": "de", "uncertain": true}',
        );
        stubHint(
          llmOf(ollamaConfig),
          json: '{"language": "de", "uncertain": true}',
        );
      });

      Future<void> expectNoDetection(
        TranslationEngine engine,
        TranslationRequest request,
        MockLlmClient client,
      ) async {
        final result = await repository.translate(engine, request).last;
        expect(result.detectionUncertain, isFalse);
        verifyNoDetection(client);
      }

      test(
        'for more than 3 words',
        () => expectNoDetection(
          claude,
          short.copyWith(text: 'Gift for the kids'),
          llmOf(claudeConfig),
        ),
      );

      test(
        'for long text without spaces',
        () => expectNoDetection(
          claude,
          short.copyWith(text: '贈り物' * 30),
          llmOf(claudeConfig),
        ),
      );

      test(
        'for an explicit source',
        () => expectNoDetection(
          claude,
          short.copyWith(source: english),
          llmOf(claudeConfig),
        ),
      );

      test(
        'for local providers',
        () => expectNoDetection(ollama, short, llmOf(ollamaConfig)),
      );

      test(
        'for engines marked local',
        () => expectNoDetection(
          TranslationEngine(
            id: claude.id,
            kind: EngineKind.ai,
            name: claude.name,
            providerId: claude.providerId,
            isLocal: true,
          ),
          short,
          llmOf(claudeConfig),
        ),
      );

      test('for translation-specialised models', () async {
        stubDetection('en');
        stubStream(llmOf(cloudGemmaConfig), ['Cadeau']);
        final result = await repository.translate(cloudGemma, short).last;
        expect(result.detectedSource, 'en');
        expect(result.detectionUncertain, isFalse);
        verifyNoDetection(llmOf(cloudGemmaConfig));
      });

      test('for engines of unknown providers', () async {
        final unknown = aiEngine(disabledConfig);
        await expectLater(
          repository.translate(unknown, short),
          emitsError(isArgumentError),
        );
      });

      test('for a provider whose model is translation-only', () async {
        // The engine claims the general profile; the provider is Hy-MT.
        final engine = TranslationEngine(
          id: cloudGemma.id,
          kind: EngineKind.ai,
          name: cloudGemma.name,
          providerId: cloudGemma.providerId,
        );
        expect(engine.supportsExtras, isTrue);
        stubDetection('en');
        stubStream(llmOf(cloudGemmaConfig), ['Cadeau']);
        await repository.translate(engine, short).drain<void>();
        verifyNoDetection(llmOf(cloudGemmaConfig));
      });

      test('in compare mode', () async {
        final entries = await repository.compare([claude], short).toList();
        expect(entries.single.result!.detectionUncertain, isFalse);
        verifyNoDetection(llmOf(claudeConfig));
      });
    });
  });

  group('TranslationResult', () {
    const base = TranslationResult(
      engineId: 'ai:claude',
      engineName: 'Claude',
      text: 'Cadeau',
      detectedSource: 'en',
    );

    test('has no detection hint by default', () {
      expect(base.detectionUncertain, isFalse);
      expect(base.detectedAlternatives, isEmpty);
      expect(base.fromCache, isFalse);
    });

    test('compares the detection hint', () {
      final uncertain = base.copyWith(
        detectionUncertain: true,
        detectedAlternatives: ['de'],
      );
      expect(uncertain, isNot(base));
      expect(
        uncertain,
        base.copyWith(detectionUncertain: true, detectedAlternatives: ['de']),
      );
      expect(
        uncertain.hashCode,
        base
            .copyWith(detectionUncertain: true, detectedAlternatives: ['de'])
            .hashCode,
      );
      expect(
        uncertain,
        isNot(uncertain.copyWith(detectedAlternatives: ['nl'])),
      );
      expect(uncertain, isNot(uncertain.copyWith(detectionUncertain: false)));
    });

    test('copyWith keeps the hint and fromCache', () {
      final hinted = base.copyWith(
        detectionUncertain: true,
        detectedAlternatives: ['de'],
        fromCache: true,
      );
      final copy = hinted.copyWith(text: 'Présent');
      expect(copy.detectionUncertain, isTrue);
      expect(copy.detectedAlternatives, ['de']);
      expect(copy.fromCache, isTrue);
    });

    test('toString mentions the hint and the cache', () {
      expect(base.toString(), isNot(contains('uncertain')));
      expect(base.toString(), isNot(contains('cached')));
      final hinted = base.copyWith(
        detectionUncertain: true,
        detectedAlternatives: ['de'],
        fromCache: true,
      );
      expect(hinted.toString(), contains('uncertain: [de]'));
      expect(hinted.toString(), contains('cached'));
    });
  });
}
