import 'dart:async';
import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  late Map<String, MockLlmClient> llm;
  late List<LlmEndpoint> llmBuilt;
  late List<Uri> mozhiBuilt;
  late TranslationRepository repository;

  MockLlmClient llmOf(AiProviderConfig config) =>
      llm[Uri.parse(config.baseUrl).host]!;

  void configure({
    List<AiProviderConfig> providers = const [
      claudeConfig,
      ollamaConfig,
      gemmaConfig,
    ],
  }) => repository.updateConfiguration(
    instances: const [instanceA],
    providers: providers,
  );

  setUp(() {
    llm = {
      for (final config in [
        claudeConfig,
        openAiConfig,
        ollamaConfig,
        gemmaConfig,
      ])
        Uri.parse(config.baseUrl).host: MockLlmClient(),
    };
    llmBuilt = [];
    mozhiBuilt = [];
    repository = TranslationRepository(
      mozhiClientFactory: (uri) {
        mozhiBuilt.add(uri);
        return MockMozhiApiClient();
      },
      llmClientFactory: (endpoint) {
        llmBuilt.add(endpoint);
        return llm[endpoint.baseUrl.host]!;
      },
      offline: FakeOfflineTranslator(),
      snapshotInterval: Duration.zero,
    );
  });

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

  List<LlmRequest> capturedStreams(MockLlmClient client) =>
      verify(() => client.streamChat(captureAny())).captured.cast<LlmRequest>();

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
  final openAi = aiEngine(openAiConfig);
  final ollama = aiEngine(ollamaConfig);
  final gemma = aiEngine(gemmaConfig);
  final offline = TranslationEngine.offline();
  final deepl = mtEngine(deeplConfig);

  group('refine', () {
    Stream<TranslationResult> refine(
      TranslationEngine engine, {
      TranslationRequest request = englishToGerman,
      String current = 'Hallo Welt',
      String instruction = 'Make the translation more formal.',
    }) => repository.refine(
      engine,
      request,
      currentTranslation: current,
      instruction: instruction,
    );

    test('streams snapshots and a cleaned final result', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['"Guten Tag, ', 'Welt"']);
      final results = await refine(claude).toList();
      expect(results.map((r) => r.text), [
        '"Guten Tag, ',
        '"Guten Tag, Welt"',
        'Guten Tag, Welt',
      ]);
      expect(results.map((r) => r.isComplete), [false, false, true]);
      expect(results.last.engineId, 'ai:claude');
      expect(results.last.engineName, 'Claude');
      expect(results.last.detectedSource, isNull);
      expect(results.last.fromCache, isFalse);
      expect(results.last.elapsed, isNotNull);
    });

    test('sends the refine prompt with the provider settings', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Guten Tag']);
      await refine(claude).drain<void>();
      final request = capturedStreams(llmOf(claudeConfig)).single;
      expect(
        request.messages,
        TranslationPrompts.refine(
          englishToGerman,
          currentTranslation: 'Hallo Welt',
          instruction: 'Make the translation more formal.',
        ),
      );
      expect(request.model, 'claude-opus-5-5');
      expect(request.temperature, isNull, reason: 'Anthropic');
      expect(request.effort, 'low');
      expect(request.jsonOutput, isFalse);
    });

    test('sends the temperature to other providers', () async {
      configure(providers: [openAiConfig]);
      stubStream(llmOf(openAiConfig), ['Guten Tag']);
      await refine(openAi).drain<void>();
      expect(capturedStreams(llmOf(openAiConfig)).single.temperature, 0.3);
    });

    test('parses the language marker for an auto source', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['[[lang:', 'en]]\n', 'Guten Tag']);
      final results = await refine(claude, request: autoToGerman).toList();
      expect(results.map((r) => r.text), everyElement(isNot(contains('['))));
      expect(results.last.text, 'Guten Tag');
      expect(results.last.detectedSource, 'en');
      expect(results.last.isComplete, isTrue);
    });

    test('is never cached', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Guten Tag']);
      await refine(claude).drain<void>();
      await refine(claude).drain<void>();
      verify(() => llmOf(claudeConfig).streamChat(any())).called(2);
    });

    test('emits nothing for blank text', () async {
      configure();
      expect(
        await refine(
          claude,
          request: englishToGerman.copyWith(text: ' \n'),
        ).toList(),
        isEmpty,
      );
      expect(llmBuilt, isEmpty);
    });

    test('rejects engines that are not AI engines', () async {
      configure();
      for (final engine in [
        TranslationEngine.mozhi('google', 'Google'),
        offline,
        deepl,
      ]) {
        await expectLater(
          refine(engine),
          emitsError(isArgumentError),
          reason: engine.id,
        );
      }
      expect(llmBuilt, isEmpty);
      expect(mozhiBuilt, isEmpty);
    });

    test('rejects unknown providers', () async {
      configure();
      await expectLater(refine(openAi), emitsError(isArgumentError));
      expect(llmBuilt, isEmpty);
    });

    test('translation-specialised models are unsupported', () async {
      configure();
      await expectLater(
        refine(gemma),
        emitsError(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('TranslateGemma only supports plain translation'),
          ),
        ),
      );
      expect(llmBuilt, isEmpty);
    });

    test('rejects a blank instruction or current translation', () async {
      configure();
      await expectLater(
        refine(claude, instruction: '  '),
        emitsError(isArgumentError),
      );
      await expectLater(
        refine(claude, current: '\n'),
        emitsError(isArgumentError),
      );
      expect(llmBuilt, isEmpty);
    });

    test('sanitises custom language names', () async {
      configure();
      stubStream(llmOf(claudeConfig), ['Arr']);
      const request = TranslationRequest(
        text: 'Hello',
        source: english,
        target: Language.custom('Pirate"\nspeak'),
      );
      await refine(claude, request: request).drain<void>();
      expect(
        capturedStreams(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.refine(
          request.copyWith(target: const Language.custom('Pirate speak')),
          currentTranslation: 'Hallo Welt',
          instruction: 'Make the translation more formal.',
        ),
      );
    });

    test('rejects a custom language that is empty after sanitising', () async {
      configure();
      await expectLater(
        refine(
          claude,
          request: englishToGerman.copyWith(
            target: const Language.custom('"«»"'),
          ),
        ),
        emitsError(isArgumentError),
      );
      expect(llmBuilt, isEmpty);
    });

    test('forwards provider errors', () async {
      configure();
      when(() => llmOf(claudeConfig).streamChat(any())).thenAnswer(
        (_) => Stream.error(const LlmApiException('quota', statusCode: 429)),
      );
      await expectLater(refine(claude), emitsError(isA<LlmApiException>()));
    });

    test('cancelling cancels the provider stream', () async {
      configure();
      final deltas = ControlledDeltas();
      when(() => llmOf(claudeConfig).streamChat(any()))
          .thenAnswer((_) => deltas.stream);
      final received = <TranslationResult>[];
      final subscription = refine(claude).listen(received.add);
      await pumpEventQueue();
      deltas.controller.add('Guten');
      await pumpEventQueue();
      expect(received.single.text, 'Guten');
      await subscription.cancel();
      expect(deltas.cancelled, isTrue);
    });
  });

  group('romanize', () {
    const japanese = Language(code: 'ja', name: 'Japanese');

    test('sends the romanize prompt and cleans the reply', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['Romaji: Tōkyō e iku\nŌsaka mo']);
      final text = await repository.romanize(
        claude,
        text: '東京へ行く\n大阪も',
        language: japanese,
      );
      expect(text, 'Tōkyō e iku\nŌsaka mo');
      final request = capturedChats(llmOf(claudeConfig)).single;
      expect(
        request.messages,
        TranslationPrompts.romanize('東京へ行く\n大阪も', language: japanese),
      );
      expect(request.jsonOutput, isFalse);
      expect(request.temperature, isNull);
    });

    test('works with an auto language', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['Privet']);
      expect(
        await repository.romanize(
          claude,
          text: 'Привет',
          language: Language.auto,
        ),
        'Privet',
      );
    });

    test('returns Latin-only text without a request', () async {
      configure();
      expect(
        await repository.romanize(
          claude,
          text: 'Tōkyō 123!',
          language: japanese,
        ),
        'Tōkyō 123!',
      );
      expect(llmBuilt, isEmpty);
    });

    test('requires an AI engine that supports extras', () async {
      configure();
      for (final engine in [
        TranslationEngine.mozhi('google', 'Google'),
        offline,
        deepl,
        gemma,
        openAi,
      ]) {
        await expectLater(
          repository.romanize(engine, text: '東京', language: japanese),
          throwsArgumentError,
          reason: engine.id,
        );
      }
      expect(llmBuilt, isEmpty);
    });

    test('throws on an empty reply', () async {
      configure();
      stubChat(llmOf(ollamaConfig), ['  \n']);
      await expectLater(
        repository.romanize(ollama, text: '東京', language: japanese),
        throwsA(isA<LlmApiException>()),
      );
    });

    test('forwards provider errors', () async {
      configure();
      when(() => llmOf(claudeConfig).chat(any()))
          .thenThrow(const LlmApiException('unauthorized', statusCode: 401));
      await expectLater(
        repository.romanize(claude, text: '東京', language: japanese),
        throwsA(isA<LlmApiException>()),
      );
    });
  });

  group('align', () {
    const source = 'the blue house';
    const translation = 'la maison bleue';
    final pairs = jsonEncode({
      'pairs': [
        {'source': 'the', 'target': 'la'},
        {'source': 'blue', 'target': 'bleue'},
        {'source': 'house', 'target': 'maison'},
        {'source': 'garden', 'target': 'jardin'},
      ],
    });

    Future<List<AlignedSpan>> align(
      TranslationEngine engine, {
      String source = source,
      String translation = translation,
    }) => repository.align(
      engine,
      source: source,
      translation: translation,
      sourceLanguage: english,
      targetLanguage: french,
    );

    test('sends the align prompt as JSON and maps the pairs', () async {
      configure();
      stubChat(llmOf(claudeConfig), [pairs]);
      final spans = await align(claude);
      expect(
        [for (final s in spans) (s.sourceIn(source), s.targetIn(translation))],
        [('the', 'la'), ('blue', 'bleue'), ('house', 'maison')],
      );
      final request = capturedChats(llmOf(claudeConfig)).single;
      expect(request.jsonOutput, isTrue);
      expect(
        request.messages,
        TranslationPrompts.align(
          source: source,
          translation: translation,
          sourceLanguage: english,
          targetLanguage: french,
        ),
      );
    });

    test('retries once with a request for valid JSON', () async {
      configure();
      stubChat(llmOf(claudeConfig), ['Here are the pairs!', pairs]);
      expect(await align(claude), hasLength(3));
      verify(() => llmOf(claudeConfig).chat(any())).called(2);
    });

    test('blank texts give no spans without a request', () async {
      configure();
      expect(await align(claude, source: ' '), isEmpty);
      expect(await align(claude, translation: ''), isEmpty);
      expect(llmBuilt, isEmpty);
    });

    test('requires an AI engine that supports extras', () async {
      configure();
      for (final engine in [
        TranslationEngine.mozhi('google', 'Google'),
        offline,
        deepl,
        gemma,
      ]) {
        await expectLater(align(engine), throwsArgumentError);
        await expectLater(align(engine, source: ''), throwsArgumentError);
      }
      expect(llmBuilt, isEmpty);
    });
  });

  group('lookUp verbosity and new fields', () {
    final entryJson = jsonEncode({
      'word': 'receive',
      'did_you_mean': 'receive',
      'senses': [
        {
          'definition': 'get',
          'translations': ['erhalten'],
        },
      ],
      'related_words': ['receipt', 'receiver', 'Receipt'],
    });

    test('passes the verbosity to the prompt', () async {
      configure();
      stubChat(llmOf(claudeConfig), [entryJson]);
      final entry = await repository.lookUp(
        claude,
        'recieve',
        source: english,
        target: german,
        verbosity: DictionaryVerbosity.comprehensive,
      );
      expect(entry.didYouMean, 'receive');
      expect(entry.relatedWords, ['receipt', 'receiver']);
      expect(
        capturedChats(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.dictionary(
          'recieve',
          source: english,
          targetLanguage: german,
          verbosity: DictionaryVerbosity.comprehensive,
        ),
      );
    });

    test('defaults to standard and drops a did_you_mean echo', () async {
      configure();
      stubChat(llmOf(claudeConfig), [entryJson]);
      final entry = await repository.lookUp(
        claude,
        'Receive',
        source: english,
        target: german,
      );
      expect(entry.didYouMean, isNull);
      expect(
        capturedChats(llmOf(claudeConfig)).single.messages,
        TranslationPrompts.dictionary(
          'Receive',
          source: english,
          targetLanguage: german,
        ),
      );
    });
  });
}
