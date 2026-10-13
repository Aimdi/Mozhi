import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  TranslationEngine? engine;
  TranslationOptions options = const TranslationOptions();
  List<Language> available = const [];

  setUp(() {
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    engine = deepl;
    options = const TranslationOptions();
    available = const [];
  });

  tearDown(() => speaking.close());

  ConversationCubit build({bool autoSpeak = false, int contextTurns = 4}) =>
      ConversationCubit(
        repository: repository,
        speech: speech,
        engine: () => engine,
        options: () => options,
        availableLanguages: () => available,
        languageA: english,
        languageB: spanish,
        autoSpeak: autoSpeak,
        contextTurns: contextTurns,
        clock: () => sentAt,
      );

  void stubTranslate(Stream<TranslationResult> Function() stream) {
    when(() => repository.translate(any(), any())).thenAnswer((_) => stream());
  }

  TranslationRequest capturedRequest() =>
      verify(() => repository.translate(any(), captureAny())).captured.last
          as TranslationRequest;

  ConversationTurn pending({
    int id = 0,
    ConversationSide side = ConversationSide.a,
    String original = 'Hello',
    TranslationEngine with_ = deepl,
  }) {
    final fromA = side == ConversationSide.a;
    return ConversationTurn(
      id: id,
      side: side,
      original: original,
      source: fromA ? english : spanish,
      target: fromA ? spanish : english,
      createdAt: sentAt,
      engineId: with_.id,
      engineName: with_.name,
    );
  }

  group('initial state', () {
    test('uses the given languages; empty, no auto-speak, standard', () {
      final cubit = build();
      expect(
        cubit.state,
        const ConversationState(languageA: english, languageB: spanish),
      );
      unawaited(cubit.close());
    });

    test('respects autoSpeak', () {
      final cubit = build(autoSpeak: true);
      expect(cubit.state.autoSpeak, isTrue);
      unawaited(cubit.close());
    });

    test('the default clock stamps turns with the current time', () async {
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = ConversationCubit(
        repository: repository,
        speech: speech,
        engine: () => deepl,
        languageA: english,
        languageB: spanish,
      );
      final before = DateTime.now();
      await cubit.submit(ConversationSide.a, 'Hello');
      expect(cubit.state.turns.single.createdAt.isBefore(before), isFalse);
      // No options or language list given: plain request.
      expect(
        capturedRequest(),
        const TranslationRequest(
          text: 'Hello',
          source: english,
          target: spanish,
        ),
      );
      await cubit.close();
    });
  });

  group('submit', () {
    blocTest<ConversationCubit, ConversationState>(
      'translates side A from language A to language B',
      setUp: () => stubTranslate(() => Stream.value(resultOf('Hola'))),
      build: build,
      act: (cubit) => cubit.submit(ConversationSide.a, '  Hello  '),
      expect: () => [
        ConversationState(
          languageA: english,
          languageB: spanish,
          turns: [pending()],
        ),
        ConversationState(
          languageA: english,
          languageB: spanish,
          turns: [pending().copyWith(translation: 'Hola')],
        ),
        ConversationState(
          languageA: english,
          languageB: spanish,
          turns: [
            pending().copyWith(
              translation: 'Hola',
              status: ConversationTurnStatus.complete,
            ),
          ],
        ),
      ],
      verify: (_) {
        expect(
          capturedRequest(),
          const TranslationRequest(
            text: 'Hello',
            source: english,
            target: spanish,
          ),
        );
        verify(() => repository.translate(deepl, any())).called(1);
        verifyNever(
          () => speech.toggle(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
          ),
        );
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'translates side B from language B to language A',
      setUp: () => stubTranslate(() => Stream.value(resultOf('Good morning'))),
      build: build,
      act: (cubit) => cubit.submit(ConversationSide.b, 'Buenos días'),
      skip: 2,
      expect: () => [
        ConversationState(
          languageA: english,
          languageB: spanish,
          turns: [
            pending(side: ConversationSide.b, original: 'Buenos días').copyWith(
              translation: 'Good morning',
              status: ConversationTurnStatus.complete,
            ),
          ],
        ),
      ],
      verify: (_) {
        final request = capturedRequest();
        expect(request.source, spanish);
        expect(request.target, english);
        expect(request.text, 'Buenos días');
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'ignores blank text',
      build: build,
      act: (cubit) => cubit.submit(ConversationSide.a, '   '),
      expect: () => <ConversationState>[],
      verify: (_) => verifyNever(() => repository.translate(any(), any())),
    );

    blocTest<ConversationCubit, ConversationState>(
      'adds a failed turn when there is no engine',
      setUp: () => engine = null,
      build: build,
      act: (cubit) => cubit.submit(ConversationSide.a, 'Hello'),
      expect: () => [
        ConversationState(
          languageA: english,
          languageB: spanish,
          turns: [
            ConversationTurn(
              id: 0,
              side: ConversationSide.a,
              original: 'Hello',
              source: english,
              target: spanish,
              createdAt: sentAt,
              status: ConversationTurnStatus.failed,
              error: const ConversationNoEngineException(),
            ),
          ],
        ),
      ],
      verify: (_) => verifyNever(() => repository.translate(any(), any())),
    );

    test('streams AI snapshots into the turn until complete', () async {
      engine = claude;
      final controller = StreamController<TranslationResult>();
      stubTranslate(() => controller.stream);
      final cubit = build();
      final states = <ConversationState>[];
      final sub = cubit.stream.listen(states.add);

      final done = cubit.submit(ConversationSide.a, 'Hello there');
      expect(cubit.state.turns.single.isTranslating, isTrue);
      expect(cubit.state.isTranslating, isTrue);
      expect(cubit.state.turns.single.engineName, 'Claude');

      controller.add(resultOf('Ho', engine: claude, isComplete: false));
      await pumpEventQueue();
      expect(cubit.state.turns.single.translation, 'Ho');
      expect(cubit.state.turns.single.isTranslating, isTrue);

      controller.add(resultOf('Hola a', engine: claude, isComplete: false));
      await pumpEventQueue();
      expect(cubit.state.turns.single.translation, 'Hola a');

      controller.add(resultOf('Hola a todos', engine: claude));
      await controller.close();
      await done;

      final turn = cubit.state.turns.single;
      expect(turn.translation, 'Hola a todos');
      expect(turn.isComplete, isTrue);
      expect(cubit.state.isTranslating, isFalse);
      expect(states.map((s) => s.turns.single.translation), [
        '',
        'Ho',
        'Hola a',
        'Hola a todos',
        'Hola a todos',
      ]);
      await sub.cancel();
      await cubit.close();
    });

    test('translates several turns at the same time', () async {
      final first = StreamController<TranslationResult>();
      final second = StreamController<TranslationResult>();
      final streams = [first, second];
      var calls = 0;
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => streams[calls++].stream);
      final cubit = build();

      final a = cubit.submit(ConversationSide.a, 'Hello');
      final b = cubit.submit(ConversationSide.b, 'Hola');
      second.add(resultOf('Hi'));
      await second.close();
      await b;
      expect(cubit.state.turns.map((t) => t.status), [
        ConversationTurnStatus.translating,
        ConversationTurnStatus.complete,
      ]);

      first.add(resultOf('Hola'));
      await first.close();
      await a;
      expect(cubit.state.turns.map((t) => t.translation), ['Hola', 'Hi']);
      expect(cubit.state.turns.map((t) => t.id), [0, 1]);
      await cubit.close();
    });

    blocTest<ConversationCubit, ConversationState>(
      'marks the turn failed on errors',
      setUp: () => stubTranslate(
        () => Stream.error(const MozhiApiException('down', statusCode: 503)),
      ),
      build: build,
      act: (cubit) => cubit.submit(ConversationSide.a, 'Hello'),
      skip: 1,
      expect: () => [
        ConversationState(
          languageA: english,
          languageB: spanish,
          turns: [
            pending().copyWith(
              status: ConversationTurnStatus.failed,
              error: () => const MozhiApiException('down', statusCode: 503),
            ),
          ],
        ),
      ],
    );

    test('keeps the partial text when a stream fails midway', () async {
      engine = claude;
      final controller = StreamController<TranslationResult>();
      stubTranslate(() => controller.stream);
      final cubit = build();
      final done = cubit.submit(ConversationSide.a, 'Hello');
      controller
        ..add(resultOf('Ho', engine: claude, isComplete: false))
        ..addError(const LlmApiException('boom'));
      await done;
      final turn = cubit.state.turns.single;
      expect(turn.isFailed, isTrue);
      expect(turn.translation, 'Ho');
      expect(turn.error, isA<LlmApiException>());
      await controller.close();
      await cubit.close();
    });

    test('maps languages onto the engine language list', () async {
      available = const [
        Language(code: 'en-US', name: 'English (US)'),
        Language(code: 'es-419', name: 'Spanish (Latin America)'),
      ];
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      final request = capturedRequest();
      expect(request.source.code, 'en-US');
      expect(request.target.code, 'es-419');
      // The transcript keeps the conversation's own languages.
      expect(cubit.state.turns.single.target, spanish);
      await cubit.close();
    });

    test('does nothing once closed', () async {
      final cubit = build();
      await cubit.close();
      await cubit.submit(ConversationSide.a, 'Hello');
      verifyNever(() => repository.translate(any(), any()));
    });
  });

  group('options', () {
    test('Mozhi engines get the translate options without context', () async {
      options = const TranslationOptions(
        formality: Formality.more,
        instructions: 'Make it shorter',
      );
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      expect(
        capturedRequest().options,
        const TranslationOptions(formality: Formality.more),
      );
      await cubit.close();
    });

    test(
      'AI engines get the conversation and recent turns as context',
      () async {
        engine = claude;
        options = const TranslationOptions(context: 'At a pharmacy');
        var replies = 0;
        when(() => repository.translate(any(), any())).thenAnswer(
          (_) => Stream.value(resultOf('reply ${replies++}', engine: claude)),
        );
        final cubit = build(contextTurns: 2);
        await cubit.submit(ConversationSide.a, 'Hello');
        expect(
          capturedRequest().options.context,
          'At a pharmacy\n'
          'This is a live spoken conversation between two people: one speaks '
          'English, the other Spanish. Translate it as natural speech.',
        );

        await cubit.submit(ConversationSide.b, 'Hola, ¿qué necesita?');
        await cubit.submit(ConversationSide.a, 'Something for a headache');
        await cubit.submit(ConversationSide.b, 'Tome esto');
        expect(
          capturedRequest().options.context,
          'At a pharmacy\n'
          'This is a live spoken conversation between two people: one speaks '
          'English, the other Spanish. Translate it as natural speech.\n'
          'Previous messages:\n'
          'Spanish speaker: Hola, ¿qué necesita?\n'
          'English speaker: Something for a headache',
        );
        await cubit.close();
      },
    );

    test('contextTurns 0 disables the context', () async {
      engine = claude;
      stubTranslate(() => Stream.value(resultOf('Hola', engine: claude)));
      final cubit = build(contextTurns: 0);
      await cubit.submit(ConversationSide.a, 'Hello');
      expect(capturedRequest().options, const TranslationOptions());
      await cubit.close();
    });
  });

  group('retry', () {
    test('translates a failed turn again', () async {
      var attempt = 0;
      when(() => repository.translate(any(), any())).thenAnswer(
        (_) => attempt++ == 0
            ? Stream.error(const MozhiApiException('down'))
            : Stream.value(resultOf('Hola')),
      );
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      expect(cubit.state.turns.single.isFailed, isTrue);

      engine = claude;
      final retried = cubit.retry(0);
      expect(cubit.state.turns.single.isTranslating, isTrue);
      expect(cubit.state.turns.single.error, isNull);
      expect(cubit.state.turns.single.engineId, claude.id);
      await retried;
      expect(cubit.state.turns.single.isComplete, isTrue);
      expect(cubit.state.turns.single.translation, 'Hola');
      await cubit.close();
    });

    test('keeps the turn failed without an engine', () async {
      stubTranslate(() => Stream.error(const MozhiApiException('down')));
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      engine = null;
      await cubit.retry(0);
      final turn = cubit.state.turns.single;
      expect(turn.isFailed, isTrue);
      expect(turn.error, isA<ConversationNoEngineException>());
      verify(() => repository.translate(any(), any())).called(1);
      await cubit.close();
    });

    test('ignores unknown and successful turns', () async {
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      await cubit.retry(0);
      await cubit.retry(42);
      verify(() => repository.translate(any(), any())).called(1);
      await cubit.close();
    });
  });

  group('speech', () {
    test('auto-speak reads each completed translation aloud', () async {
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build(autoSpeak: true);
      await cubit.submit(ConversationSide.a, 'Hello');
      await pumpEventQueue();
      verify(
        () => speech.toggle(
          id: cubit.speechIdOf(0),
          text: 'Hola',
          languageCode: 'es',
        ),
      ).called(1);

      stubTranslate(() => Stream.value(resultOf('Good morning')));
      await cubit.submit(ConversationSide.b, 'Buenos días');
      await pumpEventQueue();
      verify(
        () => speech.toggle(
          id: cubit.speechIdOf(1),
          text: 'Good morning',
          languageCode: 'en',
        ),
      ).called(1);
      await cubit.close();
    });

    test('auto-speak skips failed and empty translations', () async {
      stubTranslate(() => const Stream.empty());
      final cubit = build(autoSpeak: true);
      await cubit.submit(ConversationSide.a, 'Hello');
      stubTranslate(() => Stream.error(const MozhiApiException('down')));
      await cubit.submit(ConversationSide.a, 'Hello again');
      await pumpEventQueue();
      expect(cubit.state.turns.first.isComplete, isTrue);
      verifyNever(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      );
      await cubit.close();
    });

    test('auto-speak follows the toggle', () async {
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build()..setAutoSpeak(enabled: true);
      expect(cubit.state.autoSpeak, isTrue);
      cubit.setAutoSpeak(enabled: false);
      await cubit.submit(ConversationSide.a, 'Hello');
      await pumpEventQueue();
      verifyNever(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      );
      await cubit.close();
    });

    test('speech failures are counted', () async {
      when(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      ).thenThrow(const MozhiApiException('no tts'));
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build(autoSpeak: true);
      await cubit.submit(ConversationSide.a, 'Hello');
      await pumpEventQueue();
      expect(cubit.state.speechFailures, 1);
      await cubit.speak(0);
      expect(cubit.state.speechFailures, 2);
      await cubit.close();
    });

    test('speak toggles a turn and ignores unknown or empty ones', () async {
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      engine = null;
      await cubit.submit(ConversationSide.a, 'Nothing');

      await cubit.speak(0);
      await cubit.speak(1);
      await cubit.speak(9);
      verify(
        () => speech.toggle(
          id: cubit.speechIdOf(0),
          text: 'Hola',
          languageCode: 'es',
        ),
      ).called(1);
      verifyNever(
        () => speech.toggle(
          id: cubit.speechIdOf(1),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      );
      await cubit.close();
    });

    test('tracks which turn is being read aloud', () async {
      final cubit = build();
      speaking.add(cubit.speechIdOf(3));
      await pumpEventQueue();
      expect(cubit.state.speakingTurnId, 3);

      speaking.add(cubit.speechIdOf(3));
      await pumpEventQueue();
      expect(cubit.state.speakingTurnId, 3);

      speaking.add('target');
      await pumpEventQueue();
      expect(cubit.state.speakingTurnId, isNull);

      speaking.add(cubit.speechIdOf(4));
      await pumpEventQueue();
      speaking.add(null);
      await pumpEventQueue();
      expect(cubit.state.speakingTurnId, isNull);

      // Another conversation's ids are not ours.
      final other = build();
      speaking.add(other.speechIdOf(4));
      await pumpEventQueue();
      expect(cubit.state.speakingTurnId, isNull);
      expect(other.state.speakingTurnId, 4);
      expect(other.speechIdOf(4), isNot(cubit.speechIdOf(4)));
      await other.close();
      await cubit.close();
    });
  });

  group('removeTurn and clear', () {
    test('removeTurn cancels the translation and stops playback', () async {
      final controller = StreamController<TranslationResult>();
      stubTranslate(() => controller.stream);
      final cubit = build();
      final done = cubit.submit(ConversationSide.a, 'Hello');
      expect(controller.hasListener, isTrue);
      speaking.add(cubit.speechIdOf(0));
      await pumpEventQueue();

      await cubit.removeTurn(0);
      await done;
      expect(cubit.state.turns, isEmpty);
      expect(cubit.state.speakingTurnId, isNull);
      expect(controller.hasListener, isFalse);
      verify(speech.stop).called(1);
      await controller.close();
      await cubit.close();
    });

    test('removeTurn keeps other turns and ignores unknown ids', () async {
      stubTranslate(() => Stream.value(resultOf('Hola')));
      final cubit = build();
      await cubit.submit(ConversationSide.a, 'Hello');
      await cubit.submit(ConversationSide.a, 'Bye');
      await cubit.removeTurn(7);
      expect(cubit.state.turns, hasLength(2));
      await cubit.removeTurn(0);
      expect(cubit.state.turns.single.original, 'Bye');
      verifyNever(speech.stop);
      await cubit.close();
    });

    test('clear removes everything and cancels in-flight work', () async {
      final controller = StreamController<TranslationResult>();
      stubTranslate(() => controller.stream);
      when(speech.stop).thenThrow(StateError('player gone'));
      final cubit = build();
      final done = cubit.submit(ConversationSide.a, 'Hello');
      speaking.add(cubit.speechIdOf(0));
      await pumpEventQueue();

      await cubit.clear();
      await done;
      expect(cubit.state.turns, isEmpty);
      expect(cubit.state.speakingTurnId, isNull);
      expect(controller.hasListener, isFalse);
      verify(speech.stop).called(1);

      // Ids keep increasing so old speech ids never match new turns.
      stubTranslate(() => Stream.value(resultOf('Hola')));
      await cubit.submit(ConversationSide.a, 'Again');
      expect(cubit.state.turns.single.id, 1);
      await controller.close();
      await cubit.close();
    });

    test('clear without playback does not stop speech', () async {
      final cubit = build();
      await cubit.clear();
      verifyNever(speech.stop);
      await cubit.close();
    });
  });

  group('languages and layout', () {
    blocTest<ConversationCubit, ConversationState>(
      'setLanguage changes one side',
      build: build,
      act: (cubit) => cubit
        ..setLanguage(ConversationSide.a, french)
        ..setLanguage(ConversationSide.b, german),
      expect: () => const [
        ConversationState(languageA: french, languageB: spanish),
        ConversationState(languageA: french, languageB: german),
      ],
    );

    blocTest<ConversationCubit, ConversationState>(
      "picking the other side's language swaps",
      build: build,
      act: (cubit) => cubit.setLanguage(ConversationSide.a, spanish),
      expect: () => const [
        ConversationState(languageA: spanish, languageB: english),
      ],
    );

    blocTest<ConversationCubit, ConversationState>(
      'ignores the current, auto and custom languages',
      build: build,
      act: (cubit) => cubit
        ..setLanguage(ConversationSide.a, english)
        ..setLanguage(ConversationSide.a, Language.auto)
        ..setLanguage(ConversationSide.b, const Language.custom('Pirate')),
      expect: () => <ConversationState>[],
    );

    blocTest<ConversationCubit, ConversationState>(
      'swapLanguages',
      build: build,
      act: (cubit) => cubit.swapLanguages(),
      expect: () => const [
        ConversationState(languageA: spanish, languageB: english),
      ],
    );

    blocTest<ConversationCubit, ConversationState>(
      'setFaceToFace',
      build: build,
      act: (cubit) => cubit
        ..setFaceToFace(enabled: true)
        ..setFaceToFace(enabled: false),
      expect: () => const [
        ConversationState(
          languageA: english,
          languageB: spanish,
          faceToFace: true,
        ),
        ConversationState(languageA: english, languageB: spanish),
      ],
    );
  });

  group('close', () {
    test('cancels translations and stops its playback', () async {
      final controller = StreamController<TranslationResult>();
      stubTranslate(() => controller.stream);
      final cubit = build();
      final done = cubit.submit(ConversationSide.a, 'Hello');
      speaking.add(cubit.speechIdOf(0));
      await pumpEventQueue();
      await cubit.close();
      await done;
      expect(controller.hasListener, isFalse);
      verify(speech.stop).called(1);
      await controller.close();
    });

    test('leaves other playback alone', () async {
      final cubit = build();
      speaking.add('target');
      await pumpEventQueue();
      await cubit.close();
      verifyNever(speech.stop);
    });

    test('ignores results and speech requests after closing', () async {
      final controller = StreamController<TranslationResult>.broadcast();
      stubTranslate(() => controller.stream);
      final cubit = build();
      unawaited(cubit.submit(ConversationSide.a, 'Hello'));
      await cubit.close();
      controller.add(resultOf('Hola'));
      await pumpEventQueue();
      await cubit.speak(0);
      await cubit.retry(0);
      verifyNever(
        () => speech.toggle(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
        ),
      );
      await controller.close();
    });
  });

  group('defaultLanguages', () {
    test('uses the translate source and target', () {
      final languages = ConversationCubit.defaultLanguages(
        translateState(source: french, target: german),
      );
      expect(languages.a, french);
      expect(languages.b, german);
    });

    test('uses the detected language when the source is auto', () {
      final languages = ConversationCubit.defaultLanguages(
        translateState(
          source: Language.auto,
          target: spanish,
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Hola',
            detectedSource: 'fr',
          ),
        ),
      );
      expect(languages.a, french);
      expect(languages.a.nativeName, 'Français');
      expect(languages.b, spanish);
    });

    test('matches codes onto the engine list', () {
      const brazilian = Language(code: 'pt-BR', name: 'Portuguese (Brazil)');
      final languages = ConversationCubit.defaultLanguages(
        translateState(
          source: Language.auto,
          targetLanguages: const [english, brazilian],
          target: english,
        ),
        deviceLanguageCode: 'pt',
      );
      expect(languages.a, brazilian);
      expect(languages.b, english);
    });

    test('falls back to the device language, then English, then Spanish', () {
      expect(
        ConversationCubit.defaultLanguages(
          translateState(source: Language.auto),
          deviceLanguageCode: 'de',
        ).a,
        german,
      );
      expect(
        ConversationCubit.defaultLanguages(
          translateState(source: Language.auto),
          deviceLanguageCode: 'es',
        ).a,
        english,
      );
      expect(
        ConversationCubit.defaultLanguages(
          translateState(source: Language.auto, target: english),
          deviceLanguageCode: ' ',
        ).a,
        spanish,
      );
    });

    test('never returns the same language twice', () {
      final languages = ConversationCubit.defaultLanguages(
        translateState(source: spanish),
      );
      expect(languages.a, english);
      expect(languages.b, spanish);
    });

    test('uses English for side B when the target is a custom style', () {
      final languages = ConversationCubit.defaultLanguages(
        translateState(
          source: french,
          target: const Language.custom('Pirate speak'),
        ),
      );
      expect(languages.a, french);
      expect(languages.b, english);
    });

    test('works for codes missing from the catalogue', () {
      final languages = ConversationCubit.defaultLanguages(
        translateState(source: Language.auto, targetLanguages: const []),
        deviceLanguageCode: 'xx',
      );
      expect(languages.a.code, 'xx');
      expect(languages.a.name, 'xx');
    });
  });

  test('ConversationNoEngineException has a readable toString', () {
    expect(
      const ConversationNoEngineException().toString(),
      'ConversationNoEngineException',
    );
  });
}
