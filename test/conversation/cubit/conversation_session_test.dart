import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example.org'),
  engineId: 'mozhi:deepl',
  source: 'en',
  target: 'es',
);

const Duration _echo = ConversationCubit.defaultEchoDelay;
const Duration _silence = ConversationCubit.defaultSilenceTimeout;

/// How long reading [text] aloud may take before the session gives up.
Duration _speakingFor(String text, {bool slow = false}) =>
    ConversationCubit.speakingTimeout +
    ConversationCubit.speakingTimeoutPerCharacter *
        (text.length * (slow ? 2 : 1));

/// How long the microphone stays closed while [message] is announced.
Duration _announcing(String message) =>
    _echo + ConversationCubit.announcementPerCharacter * message.length;

void main() {
  setUpAll(registerConversationFallbacks);

  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late FakeConversationRecognizer recognizer;
  late FakeTimers timers;

  /// Every distinct session the cubit went through, in order.
  late List<ConversationSession> sessions;

  /// Whether the microphone was open at each read-aloud of a session.
  late List<bool> micOpenWhenSpeaking;

  /// What `speech.current` returns.
  String? current;
  TranslationEngine? engine;

  setUp(() {
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    recognizer = FakeConversationRecognizer();
    timers = FakeTimers();
    sessions = [];
    micOpenWhenSpeaking = [];
    current = null;
    engine = deepl;
    when(() => speech.current).thenAnswer((_) => current);
    when(
      () => speech.speak(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
        slow: any(named: 'slow'),
        allowOnline: any(named: 'allowOnline'),
      ),
    ).thenAnswer((_) async => micOpenWhenSpeaking.add(recognizer.open));
    // "Hello" -> "Hello!" and so on.
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      return Stream.value(resultOf('${request.text}!'));
    });
  });

  tearDown(() => speaking.close());

  ConversationCubit build({
    bool withRecognizer = true,
    Language languageA = english,
    Language languageB = spanish,
  }) {
    final cubit = ConversationCubit(
      repository: repository,
      speech: speech,
      engine: () => engine,
      languageA: languageA,
      languageB: languageB,
      clock: () => sentAt,
      recognizer: withRecognizer ? recognizer : null,
      timer: timers.call,
    );
    cubit.stream.listen((state) {
      final last = sessions.isEmpty ? ConversationSession.idle : sessions.last;
      if (last != state.session) {
        sessions.add(state.session);
      }
    });
    return cubit;
  }

  /// The microphone opens, then [text] is heard.
  Future<void> hear(String text, {String? language}) async {
    recognizer.start();
    await settle();
    recognizer.say(text, language: language);
    await settle();
  }

  void verifySpoke(String text, String languageCode) => verify(
    () => speech.speak(
      id: any(named: 'id'),
      text: text,
      languageCode: languageCode,
      slow: any(named: 'slow'),
      allowOnline: any(named: 'allowOnline'),
    ),
  ).called(1);

  const listeningA = ConversationSessionListening(side: ConversationSide.a);
  const listeningB = ConversationSessionListening(side: ConversationSide.b);
  final openA = listeningA.copyWith(stage: ConversationListenStage.listening);
  final openB = listeningB.copyWith(stage: ConversationListenStage.listening);

  group('hands-free availability', () {
    test('needs a recogniser', () async {
      final with_ = build();
      final without = build(withRecognizer: false);
      expect(with_.state.handsFree, isTrue);
      expect(without.state.handsFree, isFalse);
      expect(with_.state.session, ConversationSession.idle);
      await without.toggleSession();
      expect(without.state.session, ConversationSession.idle);
      expect(recognizer.listens, isEmpty);
      await with_.close();
      await without.close();
    });
  });

  group('starting', () {
    blocTest<ConversationCubit, ConversationState>(
      'listens for side A in its language and turns reading aloud on',
      build: build,
      act: (cubit) => cubit.toggleSession(),
      expect: () => [
        const ConversationState(
          languageA: english,
          languageB: spanish,
          autoSpeak: true,
          handsFree: true,
        ),
        const ConversationState(
          languageA: english,
          languageB: spanish,
          autoSpeak: true,
          handsFree: true,
          session: listeningA,
        ),
      ],
      verify: (_) {
        expect(recognizer.listens, [(language: english, detectLanguage: true)]);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'keeps reading aloud off when the user turned it off',
      build: build,
      act: (cubit) async {
        cubit
          ..setAutoSpeak(enabled: false)
          ..startSession();
        await hear('Hello');
        // Without reading aloud the other side is listened for after the
        // echo delay too: a screen reader may announce the translation.
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens, hasLength(1));
        expect(timers.pending(_echo), isTrue);
        timers.fire(_echo);
        expect(recognizer.open, isTrue);
      },
      verify: (cubit) {
        expect(cubit.state.autoSpeak, isFalse);
        verifyNever(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        );
        expect(recognizer.language, spanish);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'an empty translation listens for the other side at once',
      setUp: () =>
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => Stream.value(resultOf(' '))),
      build: build,
      act: (cubit) async {
        cubit
          ..setAutoSpeak(enabled: false)
          ..startSession();
        await hear('Hm');
        // Nothing to read or announce: no echo to wait for.
        expect(timers.pending(_echo), isFalse);
        expect(recognizer.open, isTrue);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningB);
        expect(recognizer.language, spanish);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'continues with the side after the last message',
      build: build,
      act: (cubit) async {
        await cubit.submit(ConversationSide.a, 'Hello');
        await cubit.toggleSession();
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningB);
        expect(recognizer.language, spanish);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'startSession is ignored while a session is active',
      build: build,
      act: (cubit) {
        cubit
          ..startSession()
          ..startSession(side: ConversationSide.b);
      },
      verify: (cubit) {
        expect(recognizer.listens, hasLength(1));
        expect(cubit.state.session, listeningA);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'never opens the microphone while something is read aloud',
      setUp: () => current = 'translate:target',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        expect(
          cubit.state.session,
          const ConversationSessionSpeaking(next: ConversationSide.a),
        );
        expect(recognizer.listens, isEmpty);
        current = null;
        speaking.add(null);
        await settle();
        expect(cubit.state.session, listeningA);
        expect(recognizer.listens, isEmpty);
        timers.fire(_echo);
      },
      verify: (cubit) => expect(recognizer.listens, hasLength(1)),
    );
  });

  group('a turn', () {
    blocTest<ConversationCubit, ConversationState>(
      'is heard, translated, read aloud; then the other side is heard',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        recognizer.partial('Hel');
        await settle();
        recognizer.say('Hello');
        await settle();
        // Listening for B starts after the echo delay.
        expect(recognizer.listens, hasLength(1));
        timers.fire(_echo);
        recognizer.start();
        await settle();
      },
      verify: (cubit) {
        expect(sessions, [
          listeningA,
          openA,
          openA.copyWith(heard: 'Hel'),
          const ConversationSessionTranslating(
            turnId: 0,
            speaker: ConversationSide.a,
            next: ConversationSide.b,
          ),
          const ConversationSessionSpeaking(
            turnId: 0,
            next: ConversationSide.b,
          ),
          listeningB,
          openB,
        ]);
        final turn = cubit.state.turns.single;
        expect(turn.side, ConversationSide.a);
        expect(turn.original, 'Hello');
        expect(turn.translation, 'Hello!');
        expect(turn.isComplete, isTrue);
        verifySpoke('Hello!', 'es');
        expect(recognizer.listens.map((l) => l.language), [english, spanish]);
        // The microphone was closed while reading aloud.
        expect(micOpenWhenSpeaking, [false]);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'waits until the translation was read aloud before listening',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenAnswer((invocation) async {
          current = invocation.namedArguments[#id] as String;
          speaking.add(current);
        });
        await hear('Hello');
        expect(
          cubit.state.session,
          const ConversationSessionSpeaking(
            turnId: 0,
            next: ConversationSide.b,
          ),
        );
        expect(cubit.state.speakingTurnId, 0);
        expect(timers.pending(_echo), isFalse);
        current = null;
        speaking.add(null);
        await settle();
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens, hasLength(1));
        timers.fire(_echo);
        expect(recognizer.open, isTrue);
        // The reading ended: nothing is given up.
        expect(timers.pending(_speakingFor('Hello!')), isFalse);
      },
      verify: (cubit) {
        expect(recognizer.listens.last.language, spanish);
        verifyNever(speech.stop);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'turns alternate A, B, A',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        timers.fire(_echo);
        await hear('Hola');
        timers.fire(_echo);
        await hear('Bye');
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.turns.map((turn) => turn.side), [
          ConversationSide.a,
          ConversationSide.b,
          ConversationSide.a,
        ]);
        expect(cubit.state.turns[1].source, spanish);
        expect(cubit.state.turns[1].target, english);
        expect(recognizer.listens.map((l) => l.language), [
          english,
          spanish,
          english,
          spanish,
        ]);
        expect(micOpenWhenSpeaking, [false, false, false]);
        expect(cubit.state.session, listeningB);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'shows the transcribing stage',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer
          ..start()
          ..transcribing();
        await settle();
      },
      verify: (cubit) => expect(
        cubit.state.session,
        openA.copyWith(stage: ConversationListenStage.transcribing),
      ),
    );

    blocTest<ConversationCubit, ConversationState>(
      'typed text while listening is the turn of its side',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        unawaited(cubit.submit(ConversationSide.b, 'Hola'));
        expect(recognizer.open, isFalse);
        expect(
          cubit.state.session,
          const ConversationSessionTranslating(
            turnId: 0,
            speaker: ConversationSide.b,
            next: ConversationSide.a,
          ),
        );
        await settle();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.turns.single.side, ConversationSide.b);
        verifySpoke('Hola!', 'en');
        expect(recognizer.listens.last.language, english);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'typed text while paused is a plain turn',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        timers.fire(_silence);
        await cubit.submit(ConversationSide.b, 'Hola');
      },
      verify: (cubit) {
        expect(cubit.state.turns.single.isComplete, isTrue);
        expect(
          cubit.state.session,
          const ConversationSessionPaused(
            next: ConversationSide.a,
            reason: ConversationPauseReason.silence,
          ),
        );
      },
    );
  });

  group('stopping', () {
    blocTest<ConversationCubit, ConversationState>(
      'while listening closes the microphone',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        await cubit.toggleSession();
      },
      verify: (cubit) {
        expect(cubit.state.session, ConversationSession.idle);
        expect(recognizer.open, isFalse);
        expect(recognizer.cancels, greaterThan(0));
        expect(timers.pending(_silence), isFalse);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'while waiting for the echo delay never opens the microphone',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        expect(timers.pending(_echo), isTrue);
        await cubit.stopSession();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(recognizer.listens, hasLength(1));
        expect(cubit.state.session, ConversationSession.idle);
      },
    );

    late StreamController<TranslationResult> pending;
    blocTest<ConversationCubit, ConversationState>(
      'while translating stops the translation; it can be retried',
      setUp: () {
        pending = StreamController<TranslationResult>();
        when(() => repository.translate(any(), any()))
            .thenAnswer((_) => pending.stream);
      },
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        expect(cubit.state.session, isA<ConversationSessionTranslating>());
        await cubit.toggleSession();
      },
      verify: (cubit) {
        expect(cubit.state.session, ConversationSession.idle);
        final turn = cubit.state.turns.single;
        expect(turn.isFailed, isTrue);
        expect(turn.error, isA<ConversationStoppedException>());
        expect(pending.hasListener, isFalse);
        expect(recognizer.listens, hasLength(1));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'while translating leaves the other turns alone',
      build: build,
      act: (cubit) async {
        await cubit.submit(ConversationSide.b, 'Hola');
        when(() => repository.translate(any(), any()))
            .thenAnswer((_) => StreamController<TranslationResult>().stream);
        await cubit.toggleSession();
        await hear('Hello');
        await cubit.stopSession();
      },
      verify: (cubit) {
        expect(cubit.state.turns.first.isComplete, isTrue);
        expect(
          cubit.state.turns.last.error,
          isA<ConversationStoppedException>(),
        );
        expect(
          const ConversationStoppedException().toString(),
          'ConversationStoppedException',
        );
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'while reading aloud stops the speech',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenAnswer((invocation) async {
          current = invocation.namedArguments[#id] as String;
        });
        await hear('Hello');
        expect(cubit.state.session, isA<ConversationSessionSpeaking>());
        expect(timers.pending(_speakingFor('Hello!')), isTrue);
        await cubit.toggleSession();
        expect(timers.pending(_speakingFor('Hello!')), isFalse);
        current = null;
        speaking.add(null);
        await settle();
      },
      verify: (cubit) {
        verify(speech.stop).called(1);
        expect(cubit.state.session, ConversationSession.idle);
        expect(recognizer.listens, hasLength(1));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'does nothing while idle',
      build: build,
      act: (cubit) => cubit.stopSession(),
      expect: () => <ConversationState>[],
    );

    blocTest<ConversationCubit, ConversationState>(
      'a paused session stops without reading aloud being stopped',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        timers.fire(_silence);
        await cubit.stopSession();
      },
      verify: (cubit) {
        expect(cubit.state.session, ConversationSession.idle);
        verifyNever(speech.stop);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'face-to-face mode stops the session',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        cubit.setFaceToFace(enabled: true);
        await settle();
      },
      verify: (cubit) {
        expect(cubit.state.faceToFace, isTrue);
        expect(cubit.state.session, ConversationSession.idle);
        expect(recognizer.open, isFalse);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'clearing the conversation stops the session',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        await cubit.clear();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.turns, isEmpty);
        expect(cubit.state.session, ConversationSession.idle);
        expect(recognizer.listens, hasLength(1));
      },
    );

    test('closing disposes the recogniser', () async {
      final cubit = build();
      await cubit.toggleSession();
      await cubit.close();
      expect(recognizer.disposed, isTrue);
      expect(recognizer.open, isFalse);
    });

    test('closing while reading aloud gives nothing up later', () async {
      when(
        () => speech.speak(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          slow: any(named: 'slow'),
          allowOnline: any(named: 'allowOnline'),
        ),
      ).thenAnswer((invocation) async {
        current = invocation.namedArguments[#id] as String;
      });
      final cubit = build();
      await cubit.toggleSession();
      await hear('Hello');
      expect(timers.pending(_speakingFor('Hello!')), isTrue);
      await cubit.close();
      expect(timers.pending(_speakingFor('Hello!')), isFalse);
      // What it read aloud is stopped with the page.
      verify(speech.stop).called(1);
    });

    test('closing while a translation finishes neither reads aloud nor '
        'listens', () async {
      // Closing waits a while for the speech subscription to end.
      final cancelling = Completer<void>();
      final slowly = StreamController<String?>(
        onCancel: () => cancelling.future,
      );
      when(() => speech.speaking).thenAnswer((_) => slowly.stream);
      final pending = StreamController<TranslationResult>();
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => pending.stream);
      final cubit = build();
      await cubit.toggleSession();
      await hear('Hello');
      expect(cubit.state.session, isA<ConversationSessionTranslating>());

      final closing = cubit.close();
      // The translation finishes while closing waits.
      pending.add(resultOf('Hola'));
      unawaited(pending.close());
      await settle();
      verifyNever(
        () => speech.speak(
          id: any(named: 'id'),
          text: any(named: 'text'),
          languageCode: any(named: 'languageCode'),
          slow: any(named: 'slow'),
          allowOnline: any(named: 'allowOnline'),
        ),
      );
      timers.fire(_echo);
      expect(recognizer.listens, hasLength(1));
      // Nothing can start a conversation any more either.
      cubit.startSession();
      expect(recognizer.listens, hasLength(1));
      cancelling.complete();
      await closing;
      expect(recognizer.disposed, isTrue);
    });
  });

  group('reading aloud that never ends', () {
    /// Reading aloud starts but never reports its end (Chrome's speech
    /// synthesis drops long texts without an `end` event).
    void neverEnds() =>
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenAnswer((invocation) async {
          current = invocation.namedArguments[#id] as String;
          speaking.add(current);
        });

    blocTest<ConversationCubit, ConversationState>(
      'is stopped after a while; then the other side is listened for',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        neverEnds();
        await hear('Hello');
        expect(
          cubit.state.session,
          const ConversationSessionSpeaking(
            turnId: 0,
            next: ConversationSide.b,
          ),
        );
        timers.fire(_speakingFor('Hello!'));
        await settle();
        verify(speech.stop).called(1);
        // Listened for even though the player still reports it.
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens, hasLength(1));
        timers.fire(_echo);
        expect(recognizer.open, isTrue);
      },
      verify: (cubit) => expect(recognizer.language, spanish),
    );

    blocTest<ConversationCubit, ConversationState>(
      'is listened for once when stopping it reports the end',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        neverEnds();
        when(speech.stop).thenAnswer((_) async {
          current = null;
          speaking.add(null);
        });
        await hear('Hello');
        final echoes = timers.timers.where((t) => t.duration == _echo).length;
        timers.fire(_speakingFor('Hello!'));
        await settle();
        expect(
          timers.timers.where((t) => t.duration == _echo),
          hasLength(echoes + 1),
        );
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens, hasLength(2));
      },
    );

    late Completer<void> returns;
    blocTest<ConversationCubit, ConversationState>(
      'a read-aloud that never returns is given up too',
      setUp: () => returns = Completer<void>(),
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenAnswer((_) => returns.future);
        await hear('Hello');
        expect(cubit.state.session, isA<ConversationSessionSpeaking>());
        timers.fire(_speakingFor('Hello!'));
        await settle();
        timers.fire(_echo);
        expect(recognizer.open, isTrue);
        // When it returns at last, nothing changes.
        returns.complete();
        await settle();
        expect(recognizer.open, isTrue);
      },
      verify: (cubit) {
        verify(speech.stop).called(1);
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens, hasLength(2));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'a session started while the player wrongly reports something '
      'recovers',
      setUp: () => current = 'translate:target',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        expect(
          cubit.state.session,
          const ConversationSessionSpeaking(next: ConversationSide.a),
        );
        // Nothing to go by but the base time.
        timers.fire(ConversationCubit.speakingTimeout);
        await settle();
        timers.fire(_echo);
        expect(recognizer.open, isTrue);
      },
      verify: (cubit) {
        verify(speech.stop).called(1);
        expect(cubit.state.session, listeningA);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'reading slowly may take twice as long per character',
      build: build,
      act: (cubit) async {
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenAnswer((invocation) async {
          if (invocation.namedArguments[#allowOnline] == null) {
            throw const SpeechUnavailableException('es', cause: _consent);
          }
          current = invocation.namedArguments[#id] as String;
        });
        await cubit.toggleSession();
        await hear('Hello');
        await cubit.speak(0, slow: true, allowOnline: _consent);
        expect(cubit.state.session, isA<ConversationSessionSpeaking>());
        expect(timers.pending(_speakingFor('Hello!', slow: true)), isTrue);
        expect(timers.pending(_speakingFor('Hello!')), isFalse);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'switching turns meanwhile listens for the chosen side',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        neverEnds();
        await hear('Hello');
        cubit.switchTurn(ConversationSide.a);
        timers.fire(_speakingFor('Hello!'));
        await settle();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningA);
        expect(recognizer.language, english);
      },
    );
  });

  group('screen reader announcements', () {
    const announcement = 'Spanish: Hello!';

    blocTest<ConversationCubit, ConversationState>(
      'hold the microphone until they were probably said',
      build: build,
      act: (cubit) async {
        cubit
          ..setAutoSpeak(enabled: false)
          ..startSession();
        await hear('Hello');
        expect(timers.pending(_echo), isTrue);
        cubit.announced(announcement);
        expect(timers.pending(_echo), isFalse);
        expect(timers.pending(_announcing(announcement)), isTrue);
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens, hasLength(1));
        timers.fire(_announcing(announcement));
        expect(recognizer.open, isTrue);
      },
      verify: (cubit) {
        expect(recognizer.listens, hasLength(2));
        expect(recognizer.language, spanish);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'close an open microphone until they ended',
      build: build,
      act: (cubit) async {
        cubit.startSession();
        recognizer.start();
        await settle();
        expect(timers.pending(_silence), isTrue);
        cubit.announced(announcement);
        expect(recognizer.open, isFalse);
        expect(cubit.state.session, listeningA);
        expect(timers.pending(_silence), isFalse);
        timers.fire(_announcing(announcement));
        expect(recognizer.open, isTrue);
      },
      verify: (cubit) {
        expect(recognizer.listens, hasLength(2));
        expect(recognizer.language, english);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'change nothing unless the conversation listens',
      build: build,
      act: (cubit) => cubit
        ..announced(announcement)
        ..announced('  '),
      expect: () => <ConversationState>[],
      verify: (_) => expect(timers.timers, isEmpty),
    );

    blocTest<ConversationCubit, ConversationState>(
      'stopping meanwhile never opens the microphone',
      build: build,
      act: (cubit) async {
        cubit
          ..startSession()
          ..announced(announcement);
        await cubit.stopSession();
        timers.fire(_announcing(announcement));
      },
      verify: (cubit) {
        expect(recognizer.open, isFalse);
        expect(cubit.state.session, ConversationSession.idle);
      },
    );
  });

  group('switching turns', () {
    blocTest<ConversationCubit, ConversationState>(
      'while listening listens for the chosen side',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        cubit
          ..switchTurn(ConversationSide.a)
          ..switchTurn(ConversationSide.b);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens.map((l) => l.language), [english, spanish]);
      },
    );

    late StreamController<TranslationResult> pending;
    blocTest<ConversationCubit, ConversationState>(
      'while translating chooses who is listened for next',
      setUp: () {
        pending = StreamController<TranslationResult>();
        when(() => repository.translate(any(), any()))
            .thenAnswer((_) => pending.stream);
      },
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        cubit.switchTurn(ConversationSide.a);
        expect(
          cubit.state.session,
          const ConversationSessionTranslating(
            turnId: 0,
            speaker: ConversationSide.a,
            next: ConversationSide.a,
          ),
        );
        pending.add(resultOf('Hola'));
        await pending.close();
        await settle();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningA);
        expect(recognizer.listens.map((l) => l.language), [english, english]);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'while reading aloud chooses who is listened for next',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenAnswer((invocation) async {
          current = invocation.namedArguments[#id] as String;
        });
        await hear('Hello');
        cubit.switchTurn(ConversationSide.a);
        expect(
          cubit.state.session,
          const ConversationSessionSpeaking(
            turnId: 0,
            next: ConversationSide.a,
          ),
        );
        current = null;
        speaking.add(null);
        await settle();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningA);
        expect(recognizer.language, english);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'while paused continues with the chosen side',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        timers.fire(_silence);
        cubit.switchTurn(ConversationSide.b);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningB);
        expect(recognizer.language, spanish);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'while idle does nothing',
      build: build,
      act: (cubit) => cubit.switchTurn(ConversationSide.b),
      expect: () => <ConversationState>[],
    );

    blocTest<ConversationCubit, ConversationState>(
      'changing a language while listening listens in the new one',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        cubit.setLanguage(ConversationSide.a, french);
        expect(recognizer.language, french);
        cubit.swapLanguages();
      },
      verify: (cubit) {
        expect(cubit.state.languageA, spanish);
        expect(cubit.state.session, listeningA);
        expect(recognizer.listens.map((l) => l.language), [
          english,
          french,
          spanish,
        ]);
      },
    );
  });

  group('language detection', () {
    blocTest<ConversationCubit, ConversationState>(
      'gives the turn to the side whose language was heard',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start(detectsLanguage: true);
        await settle();
        expect(cubit.state.session, openA.copyWith(detectsLanguage: true));
        recognizer.say('Hola', language: 'es');
        await settle();
        timers.fire(_echo);
      },
      verify: (cubit) {
        final turn = cubit.state.turns.single;
        expect(turn.side, ConversationSide.b);
        expect(turn.source, spanish);
        expect(turn.target, english);
        verifySpoke('Hola!', 'en');
        // Then side A answers.
        expect(cubit.state.session, listeningA);
        expect(recognizer.language, english);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'matches regional variants and other spellings',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hola', language: 'ES-mx');
      },
      verify: (cubit) =>
          expect(cubit.state.turns.single.side, ConversationSide.b),
    );

    blocTest<ConversationCubit, ConversationState>(
      'keeps the expected side for a third language',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Bonjour', language: 'fr');
      },
      verify: (cubit) =>
          expect(cubit.state.turns.single.side, ConversationSide.a),
    );

    blocTest<ConversationCubit, ConversationState>(
      'keeps the expected side without a detected language',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello', language: ' ');
      },
      verify: (cubit) =>
          expect(cubit.state.turns.single.side, ConversationSide.a),
    );

    blocTest<ConversationCubit, ConversationState>(
      'is not asked for when both sides speak the same language',
      build: () => build(
        languageA: const Language(code: 'pt-BR', name: 'Portuguese (Brazil)'),
        languageB: const Language(code: 'pt-PT', name: 'Portuguese (Portugal)'),
      ),
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Olá', language: 'pt');
      },
      verify: (cubit) {
        expect(recognizer.listens.first.detectLanguage, isFalse);
        expect(cubit.state.turns.single.side, ConversationSide.a);
      },
    );
  });

  group('silence', () {
    blocTest<ConversationCubit, ConversationState>(
      'pauses after the silence timeout',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        expect(timers.pending(_silence), isTrue);
        timers.fire(_silence);
      },
      verify: (cubit) {
        expect(
          cubit.state.session,
          const ConversationSessionPaused(
            next: ConversationSide.a,
            reason: ConversationPauseReason.silence,
          ),
        );
        expect(recognizer.open, isFalse);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'nothing heard before the timeout listens again, same timeout',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        recognizer.fail(SpeechInputFailure.noMatch);
        await settle();
        expect(cubit.state.session, listeningA);
        expect(recognizer.listens, hasLength(2));
        recognizer.start();
        await settle();
        recognizer.end();
        await settle();
        expect(recognizer.listens, hasLength(3));
        recognizer.start();
        await settle();
        // One timeout for the whole wait.
        expect(
          timers.timers.where((t) => t.duration == _silence),
          hasLength(1),
        );
        timers.fire(_silence);
      },
      verify: (cubit) => expect(
        cubit.state.session,
        isA<ConversationSessionPaused>().having(
          (session) => session.reason,
          'reason',
          ConversationPauseReason.silence,
        ),
      ),
    );

    blocTest<ConversationCubit, ConversationState>(
      'background noise does not stop the timeout',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer
          ..start()
          // Loud relative to the digital silence of the first chunk.
          ..level(1)
          ..partial('  ');
        await settle();
        expect(timers.pending(_silence), isTrue);
        timers.fire(_silence);
      },
      verify: (cubit) {
        expect(
          cubit.state.session,
          const ConversationSessionPaused(
            next: ConversationSide.a,
            reason: ConversationPauseReason.silence,
          ),
        );
        expect(recognizer.open, isFalse);
        expect(recognizer.listens, hasLength(1));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'someone speaking stops the timeout; unintelligible speech retries',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer
          ..start()
          ..level(0.2);
        await settle();
        expect(timers.pending(_silence), isTrue);
        recognizer.speech();
        await settle();
        expect(timers.pending(_silence), isFalse);
        recognizer.say('   ');
        await settle();
        recognizer.start();
        await settle();
        // A new wait starts after the unintelligible speech.
        expect(timers.pending(_silence), isTrue);
      },
      verify: (cubit) {
        expect(cubit.state.session, openA);
        expect(cubit.state.turns, isEmpty);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'too many empty utterances in a row pause',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        for (var i = 0; i < ConversationCubit.maxEmptyUtterances; i++) {
          recognizer
            ..start()
            ..partial('mm');
          await settle();
          recognizer.fail(SpeechInputFailure.noMatch);
          await settle();
        }
      },
      verify: (cubit) {
        expect(recognizer.listens, hasLength(4));
        expect(cubit.state.session, isA<ConversationSessionPaused>());
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'an utterance that ends before the microphone opened pauses',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.end();
        await settle();
      },
      verify: (cubit) =>
          expect(cubit.state.session, isA<ConversationSessionPaused>()),
    );

    blocTest<ConversationCubit, ConversationState>(
      'the microphone taken over pauses',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        recognizer.end(interrupted: true);
        await settle();
      },
      verify: (cubit) => expect(
        cubit.state.session,
        const ConversationSessionPaused(
          next: ConversationSide.a,
          reason: ConversationPauseReason.interrupted,
        ),
      ),
    );

    blocTest<ConversationCubit, ConversationState>(
      'tapping a paused session continues it',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        timers.fire(_silence);
        await cubit.toggleSession();
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningA);
        expect(recognizer.listens, hasLength(2));
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'a timeout after someone spoke changes nothing',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer
          ..start()
          ..partial('Hel');
        await settle();
        timers.fire(_silence);
      },
      verify: (cubit) =>
          expect(cubit.state.session, openA.copyWith(heard: 'Hel')),
    );
  });

  group('voice input errors', () {
    blocTest<ConversationCubit, ConversationState>(
      'fail the session; tapping tries again',
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        recognizer.fail(
          SpeechInputFailure.offlineModelMissing,
          onDevice: true,
          offlineSupported: true,
        );
        await settle();
        expect(
          cubit.state.session,
          const ConversationSessionFailed(
            next: ConversationSide.a,
            failure: SpeechInputFailure.offlineModelMissing,
            onDevice: true,
            offlineSupported: true,
          ),
        );
        expect(cubit.state.session.isActive, isTrue);
        expect(cubit.state.session.isRunning, isFalse);
        await cubit.toggleSession();
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningA);
        expect(recognizer.listens, hasLength(2));
      },
    );
  });

  group('consent and failures', () {
    blocTest<ConversationCubit, ConversationState>(
      'a translation that needs consent pauses; granting it continues',
      setUp: () {
        var asked = false;
        when(() => repository.translate(any(), any())).thenAnswer((_) {
          if (asked) return Stream.value(resultOf('Hola'));
          asked = true;
          return Stream.error(_consent);
        });
      },
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        expect(
          cubit.state.session,
          const ConversationSessionPaused(
            next: ConversationSide.b,
            reason: ConversationPauseReason.consent,
            turnId: 0,
          ),
        );
        expect(recognizer.open, isFalse);
        await cubit.retry(0);
        await settle();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(
          sessions,
          containsAllInOrder([
            const ConversationSessionTranslating(
              turnId: 0,
              speaker: ConversationSide.a,
              next: ConversationSide.b,
            ),
            const ConversationSessionSpeaking(
              turnId: 0,
              next: ConversationSide.b,
            ),
            listeningB,
          ]),
        );
        verifySpoke('Hola', 'es');
        expect(recognizer.language, spanish);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'a failed translation pauses; retrying continues',
      setUp: () {
        var failed = false;
        when(() => repository.translate(any(), any())).thenAnswer((_) {
          if (failed) return Stream.value(resultOf('Hola'));
          failed = true;
          return Stream.error(Exception('offline'));
        });
      },
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        expect(
          cubit.state.session,
          const ConversationSessionPaused(
            next: ConversationSide.b,
            reason: ConversationPauseReason.translationFailed,
            turnId: 0,
          ),
        );
        await cubit.retry(0);
        await settle();
      },
      verify: (cubit) => expect(cubit.state.session, listeningB),
    );

    blocTest<ConversationCubit, ConversationState>(
      'retrying another turn leaves the pause alone',
      setUp: () =>
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => Stream.error(Exception('offline'))),
      build: build,
      act: (cubit) async {
        await cubit.submit(ConversationSide.a, 'Typed');
        await cubit.toggleSession();
        await hear('Hello');
        await cubit.retry(0);
      },
      verify: (cubit) => expect(
        cubit.state.session,
        const ConversationSessionPaused(
          next: ConversationSide.a,
          reason: ConversationPauseReason.translationFailed,
          turnId: 1,
        ),
      ),
    );

    blocTest<ConversationCubit, ConversationState>(
      'no engine pauses at the turn',
      setUp: () => engine = null,
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
      },
      verify: (cubit) {
        expect(cubit.state.turns.single.isFailed, isTrue);
        expect(
          cubit.state.session,
          const ConversationSessionPaused(
            next: ConversationSide.b,
            reason: ConversationPauseReason.translationFailed,
            turnId: 0,
          ),
        );
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'reading aloud that needs consent pauses; listening online continues',
      build: build,
      act: (cubit) async {
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenAnswer((invocation) async {
          if (invocation.namedArguments[#allowOnline] == null) {
            throw const SpeechUnavailableException('es', cause: _consent);
          }
        });
        await cubit.toggleSession();
        await hear('Hello');
        expect(
          cubit.state.session,
          const ConversationSessionPaused(
            next: ConversationSide.b,
            reason: ConversationPauseReason.speechConsent,
            turnId: 0,
          ),
        );
        expect(cubit.state.speechFailures, 1);
        expect(cubit.state.lastSpeechFailure?.asked, isFalse);
        await cubit.speak(0, allowOnline: _consent);
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningB);
        expect(recognizer.language, spanish);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'other reading aloud failures are reported and listening goes on',
      build: build,
      act: (cubit) async {
        when(
          () => speech.speak(
            id: any(named: 'id'),
            text: any(named: 'text'),
            languageCode: any(named: 'languageCode'),
            slow: any(named: 'slow'),
            allowOnline: any(named: 'allowOnline'),
          ),
        ).thenThrow(const SpeechUnavailableException('es'));
        await cubit.toggleSession();
        await hear('Hello');
      },
      verify: (cubit) {
        expect(cubit.state.speechFailures, 1);
        // Nothing was read aloud: no echo to wait for.
        expect(cubit.state.session, listeningB);
        expect(recognizer.listens, hasLength(2));
      },
    );
  });

  group('reading aloud by hand', () {
    blocTest<ConversationCubit, ConversationState>(
      'closes the microphone and listens again afterwards',
      build: build,
      act: (cubit) async {
        await cubit.submit(ConversationSide.b, 'Hola');
        await cubit.toggleSession();
        recognizer.start();
        await settle();
        current = cubit.speechIdOf(0);
        speaking.add(current);
        await settle();
        expect(recognizer.open, isFalse);
        expect(
          cubit.state.session,
          const ConversationSessionSpeaking(
            turnId: 0,
            next: ConversationSide.a,
          ),
        );
        current = null;
        speaking.add(null);
        await settle();
        timers.fire(_echo);
      },
      verify: (cubit) {
        expect(cubit.state.session, listeningA);
        expect(recognizer.listens.map((l) => l.language), [english, english]);
      },
    );

    blocTest<ConversationCubit, ConversationState>(
      'removing the turn being translated listens for the next side',
      setUp: () =>
          when(() => repository.translate(any(), any()))
              .thenAnswer((_) => StreamController<TranslationResult>().stream),
      build: build,
      act: (cubit) async {
        await cubit.toggleSession();
        await hear('Hello');
        await cubit.removeTurn(0);
      },
      verify: (cubit) {
        expect(cubit.state.turns, isEmpty);
        expect(cubit.state.session, listeningB);
      },
    );
  });

  group('ConversationSession', () {
    test('idle is neither running nor active and has no side', () {
      expect(ConversationSession.idle.isRunning, isFalse);
      expect(ConversationSession.idle.isActive, isFalse);
      expect(ConversationSession.idle.side, isNull);
    });

    test('paused and failed are active with their next side', () {
      const paused = ConversationSessionPaused(
        next: ConversationSide.b,
        reason: ConversationPauseReason.silence,
      );
      const failed = ConversationSessionFailed(
        next: ConversationSide.a,
        failure: SpeechInputFailure.audio,
      );
      expect(paused.isActive && !paused.isRunning, isTrue);
      expect(paused.side, ConversationSide.b);
      expect(failed.isActive && !failed.isRunning, isTrue);
      expect(failed.side, ConversationSide.a);
    });

    test('running stages name whose turn it is', () {
      const translating = ConversationSessionTranslating(
        turnId: 1,
        speaker: ConversationSide.b,
        next: ConversationSide.a,
      );
      const speaking = ConversationSessionSpeaking(next: ConversationSide.a);
      expect(translating.side, ConversationSide.b);
      expect(speaking.side, ConversationSide.a);
      expect(listeningA.side, ConversationSide.a);
      expect(translating.isRunning && speaking.isRunning, isTrue);
    });
  });
}
