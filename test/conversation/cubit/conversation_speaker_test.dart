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
  late FakeConversationRecognizer recognizer;
  late FakeTimers timers;

  setUp(() {
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    recognizer = FakeConversationRecognizer();
    timers = FakeTimers();
    when(() => speech.current).thenReturn(null);
    when(
      () => speech.speak(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        slow: any(named: 'slow'),
        allowOnline: any(named: 'allowOnline'),
      ),
    ).thenAnswer((_) async {});
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      return Stream.value(resultOf('${request.text}!'));
    });
  });

  tearDown(() => speaking.close());

  ConversationCubit build({Language languageB = spanish}) => ConversationCubit(
    repository: repository,
    speech: speech,
    engine: () => deepl,
    languageA: english,
    languageB: languageB,
    clock: () => sentAt,
    recognizer: recognizer,
    timer: timers.call,
  );

  /// The microphone opens (a recogniser that detects the language), then
  /// [text] is heard in [language].
  Future<void> hear(String text, {String? language}) async {
    recognizer.start(detectsLanguage: true);
    await settle();
    recognizer.say(text, language: language);
    await settle();
  }

  group('defaults', () {
    test('detect the speaker and end a turn after 0.8 s', () {
      const state = ConversationState(languageA: english, languageB: spanish);
      expect(state.detectSpeaker, isTrue);
      expect(state.turnPause, const Duration(milliseconds: 800));
      expect(
        state.copyWith(detectSpeaker: false, turnPause: Duration.zero),
        isNot(state),
      );
      expect(
        state.copyWith(),
        const ConversationState(languageA: english, languageB: spanish),
      );
    });

    blocTest<ConversationCubit, ConversationState>(
      'listen with detection and the pause',
      build: build,
      act: (cubit) => cubit.toggleSession(),
      verify: (_) {
        expect(recognizer.listens, [(language: english, detectLanguage: true)]);
        expect(recognizer.pauses, [ConversationState.defaultTurnPause]);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'never detect between variants of one language',
      build: () => build(
        languageB: const Language(code: 'en-GB', name: 'British'),
      ),
      act: (cubit) => cubit.toggleSession(),
      verify: (_) => expect(recognizer.listens.single.detectLanguage, isFalse),
    );
  });

  group('detect the speaker', () {
    blocTest<ConversationCubit, ConversationState>(
      'gives the turn to the side whose language was heard',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        // Listening for A (English), B answers in Spanish.
        await hear('Hola', language: 'es');
      },
      verify: (cubit) {
        final turn = cubit.state.turns.single;
        expect(turn.side, ConversationSide.b);
        expect(turn.source, spanish);
        expect(turn.target, english);
        // Then A is listened for.
        expect(cubit.state.session.side, ConversationSide.a);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'keeps the current side for another or an unknown language',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Bonjour', language: 'fr');
        timers.fire(ConversationCubit.defaultEchoDelay);
        await hear('Hello');
      },
      verify: (cubit) {
        expect(cubit.state.turns.map((turn) => turn.side), [
          ConversationSide.a,
          ConversationSide.b,
        ]);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'off: the side whose turn it is speaks, in its own language',
      build: build,
      act: (cubit) async {
        cubit.setDetectSpeaker(enabled: false);
        await cubit.toggleSession();
        // Whisper heard Spanish, but A's turn is A's.
        await hear('Hola', language: 'es');
      },
      expect: () => contains(
        isA<ConversationState>().having(
          (state) => state.detectSpeaker,
          'detectSpeaker',
          isFalse,
        ),
      ),
      verify: (cubit) {
        expect(recognizer.listens.first, (
          language: english,
          detectLanguage: false,
        ));
        expect(cubit.state.turns.single.side, ConversationSide.a);
        expect(cubit.state.turns.single.source, english);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'changing it while listening starts over with it',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start(detectsLanguage: true);
        await settle();
        cubit.setDetectSpeaker(enabled: false);
        await settle();
        // Unchanged: nothing starts over.
        cubit.setDetectSpeaker(enabled: false);
        await settle();
      },
      verify: (cubit) {
        expect(recognizer.listens, [
          (language: english, detectLanguage: true),
          (language: english, detectLanguage: false),
        ]);
        expect(
          cubit.state.session,
          const ConversationSessionListening(side: ConversationSide.a),
        );
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'changing it while idle only stores it',
      build: build,
      act: (cubit) => cubit.setDetectSpeaker(enabled: false),
      expect: () => [
        isA<ConversationState>().having(
          (state) => state.detectSpeaker,
          'detectSpeaker',
          isFalse,
        ),
      ],
      verify: (_) => expect(recognizer.listens, isEmpty),
    );
  });

  group('turn pause', () {
    blocTest<ConversationCubit, ConversationState>(
      'is kept between 0.5 and 2 s',
      build: build,
      act: (cubit) {
        cubit
          ..setTurnPause(const Duration(milliseconds: 1200))
          ..setTurnPause(const Duration(milliseconds: 100))
          ..setTurnPause(const Duration(seconds: 5))
          // Unchanged: nothing new.
          ..setTurnPause(const Duration(seconds: 3));
      },
      expect: () => [
        for (final pause in const [
          Duration(milliseconds: 1200),
          ConversationState.minTurnPause,
          ConversationState.maxTurnPause,
        ])
          isA<ConversationState>().having(
            (state) => state.turnPause,
            'turnPause',
            pause,
          ),
      ],
    );

    blocTest<ConversationCubit, ConversationState>(
      'applies from the next utterance on',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        cubit.setTurnPause(const Duration(milliseconds: 1500));
        await hear('Hello');
        timers.fire(ConversationCubit.defaultEchoDelay);
        await settle();
      },
      verify: (_) {
        expect(recognizer.pauses, [
          ConversationState.defaultTurnPause,
          const Duration(milliseconds: 1500),
        ]);
      },
    );
  });
}
