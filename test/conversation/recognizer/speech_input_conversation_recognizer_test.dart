import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/voice/voice.dart';

import '../../voice/helpers/fake_speech_recognizer.dart';
import '../helpers.dart';

class _MockSpeechInputService extends Mock implements SpeechInputService;

const Duration _grace = SpeechInputConversationRecognizer.finalResultGrace;

void main() {
  setUpAll(registerConversationFallbacks);

  group('SpeechInputConversationRecognizer', () {
    late _MockSpeechInputService service;
    late StreamController<SpeechInputState> states;
    late StreamController<SpeechInputResult> results;
    late SpeechInputState state;
    late FakeTimers timers;
    late SpeechInputConversationRecognizer recognizer;

    /// The owner of the last session started.
    Object? owner;

    /// What `listen` does after recording its owner; returns whether
    /// listening started.
    late FutureOr<bool> Function() onListen;

    setUp(() {
      service = _MockSpeechInputService();
      states = StreamController.broadcast();
      results = StreamController.broadcast();
      state = const SpeechInputIdle();
      owner = null;
      onListen = () {
        states.add(SpeechInputListening(owner: owner));
        return true;
      };
      when(() => service.states).thenAnswer((_) => states.stream);
      when(() => service.results).thenAnswer((_) => results.stream);
      when(() => service.state).thenAnswer((_) => state);
      when(() => service.preferOnDevice).thenReturn(ValueNotifier(true));
      when(() => service.isOfflineSupported).thenReturn(true);
      when(service.cancel).thenAnswer((_) async {});
      when(
        () => service.listen(
          any(),
          owner: any(named: 'owner'),
          detectLanguage: any(named: 'detectLanguage'),
        ),
      ).thenAnswer((invocation) async {
        owner = invocation.namedArguments[#owner];
        return await onListen();
      });
      timers = FakeTimers();
      recognizer = SpeechInputConversationRecognizer(
        service,
        timer: timers.call,
      );
    });

    tearDown(() async {
      await states.close();
      await results.close();
    });

    /// Collects the events of an utterance and whether it ended.
    ({List<ConversationHearing> events, bool Function() done}) collect(
      Stream<ConversationHearing> stream,
    ) {
      final events = <ConversationHearing>[];
      var done = false;
      stream.listen(events.add, onDone: () => done = true);
      return (events: events, done: () => done);
    }

    test('reports the start, levels, words and the final result', () async {
      final heard = collect(recognizer.listen(spanish, detectLanguage: true));
      await settle();
      verify(() => service.listen('es', owner: owner, detectLanguage: true))
          .called(1);
      states
        ..add(SpeechInputListening(owner: owner, level: 0.3))
        ..add(SpeechInputListening(owner: owner, level: 0.3));
      results
        ..add(SpeechInputResult('Ho', isFinal: false, owner: owner))
        // Someone else's words.
        ..add(const SpeechInputResult('Hi', isFinal: false));
      await settle();
      results.add(
        SpeechInputResult('Hola', isFinal: true, owner: owner, language: 'es'),
      );
      await settle();
      expect(heard.events, const [
        ConversationHeardStart(),
        ConversationHeardLevel(0.3),
        ConversationHeardPartial('Ho'),
        ConversationHeardFinal('Hola', language: 'es'),
      ]);
      expect(heard.done(), isTrue);
    });

    test('reports speech once, not loudness alone', () async {
      final heard = collect(recognizer.listen(english));
      await settle();
      states
        // Background noise.
        ..add(SpeechInputListening(owner: owner, level: 1))
        ..add(SpeechInputListening(owner: owner, level: 1, heardSpeech: true))
        ..add(
          SpeechInputListening(owner: owner, level: 0.4, heardSpeech: true),
        );
      await settle();
      expect(heard.events, const [
        ConversationHeardStart(),
        ConversationHeardLevel(1),
        ConversationHeardSpeech(),
        ConversationHeardLevel(0.4),
      ]);
    });

    test('says whether the language is detected', () async {
      onListen = () {
        states.add(SpeechInputListening(owner: owner, detectsLanguage: true));
        return true;
      };
      final heard = collect(recognizer.listen(english));
      await settle();
      expect(heard.events, const [
        ConversationHeardStart(detectsLanguage: true),
      ]);
    });

    test('reports transcribing', () async {
      final heard = collect(recognizer.listen(english));
      await settle();
      states.add(SpeechInputTranscribing(owner: owner));
      await settle();
      expect(heard.events.last, const ConversationHeardTranscribing());
    });

    test('reports its errors with what their message needs', () async {
      final heard = collect(recognizer.listen(english));
      await settle();
      states.add(
        SpeechInputError(
          'error_permission',
          permanent: true,
          failure: SpeechInputFailure.permissionDenied,
          owner: owner,
        ),
      );
      await settle();
      expect(
        heard.events.last,
        const ConversationHeardFailure(
          SpeechInputFailure.permissionDenied,
          onDevice: true,
          offlineSupported: true,
        ),
      );
      expect(heard.done(), isTrue);
    });

    test('ends when the session ends without a result', () async {
      onListen = () => true;
      final heard = collect(recognizer.listen(english));
      // An idle state from before the start is not the end.
      states.add(const SpeechInputIdle());
      await settle();
      expect(heard.done(), isFalse);
      expect(timers.pending(_grace), isFalse);
      states
        ..add(SpeechInputListening(owner: owner))
        ..add(const SpeechInputIdle());
      await settle();
      // The final result may still follow.
      expect(heard.done(), isFalse);
      timers.fire(_grace);
      await settle();
      expect(heard.events.last, const ConversationHeardEnd());
      expect(heard.done(), isTrue);
    });

    group('after the microphone closed', () {
      /// Starts an utterance whose microphone then closes (Android reports
      /// `notListening` before the final result).
      Future<({List<ConversationHearing> events, bool Function() done})>
      closed() async {
        final heard = collect(recognizer.listen(english));
        await settle();
        states.add(const SpeechInputIdle());
        await settle();
        expect(heard.done(), isFalse);
        expect(timers.pending(_grace), isTrue);
        return heard;
      }

      test('waits for a final result that arrives late', () async {
        final heard = await closed();
        results.add(
          SpeechInputResult('Good morning', isFinal: true, owner: owner),
        );
        await settle();
        expect(heard.events, const [
          ConversationHeardStart(),
          ConversationHeardFinal('Good morning'),
        ]);
        expect(heard.done(), isTrue);
        expect(timers.pending(_grace), isFalse);
      });

      test('still reports late words', () async {
        final heard = await closed();
        results.add(SpeechInputResult('Good', isFinal: false, owner: owner));
        await settle();
        expect(heard.events.last, const ConversationHeardPartial('Good'));
        expect(heard.done(), isFalse);
      });

      test('ends with its error, e.g. nothing recognised', () async {
        final heard = await closed();
        states.add(
          SpeechInputError(
            'error_no_match',
            permanent: false,
            failure: SpeechInputFailure.noMatch,
            owner: owner,
          ),
        );
        await settle();
        expect(
          heard.events.last,
          isA<ConversationHeardFailure>().having(
            (event) => event.failure,
            'failure',
            SpeechInputFailure.noMatch,
          ),
        );
        expect(timers.pending(_grace), isFalse);
      });

      test('ends as interrupted when another owner takes over', () async {
        final heard = await closed();
        states.add(const SpeechInputListening());
        await settle();
        expect(
          heard.events.last,
          const ConversationHeardEnd(interrupted: true),
        );
        expect(timers.pending(_grace), isFalse);
      });

      test("ends at once with someone else's error", () async {
        final heard = await closed();
        states.add(const SpeechInputError('busy', permanent: false));
        await settle();
        expect(heard.events.last, const ConversationHeardEnd());
        expect(timers.pending(_grace), isFalse);
      });

      test('cancelling ends it quietly', () async {
        final heard = await closed();
        await recognizer.cancel();
        await settle();
        expect(heard.events, const [ConversationHeardStart()]);
        expect(heard.done(), isTrue);
        expect(timers.pending(_grace), isFalse);
        // The service is idle: nothing of ours to cancel.
        verifyNever(service.cancel);
      });
    });

    test('ends as interrupted when another owner takes over', () async {
      onListen = () => true;
      final heard = collect(recognizer.listen(english));
      // Another owner before the start is not an interruption.
      states.add(const SpeechInputListening());
      await settle();
      expect(heard.done(), isFalse);
      states
        ..add(SpeechInputListening(owner: owner))
        ..add(const SpeechInputTranscribing());
      await settle();
      expect(heard.events.last, const ConversationHeardEnd(interrupted: true));
    });

    test('fails when voice input becomes unavailable', () async {
      final heard = collect(recognizer.listen(english));
      await settle();
      states.add(const SpeechInputUnavailable());
      await settle();
      expect(
        heard.events.last,
        const ConversationHeardFailure(
          SpeechInputFailure.recognizerUnavailable,
          onDevice: true,
          offlineSupported: true,
        ),
      );
    });

    group('a session that does not start', () {
      Future<ConversationHearing> lastEventWhen(SpeechInputState now) async {
        onListen = () {
          state = now;
          return false;
        };
        final heard = collect(recognizer.listen(english));
        await settle();
        expect(heard.done(), isTrue);
        return heard.events.single;
      }

      test('fails with the reason it is unavailable', () async {
        expect(
          await lastEventWhen(
            const SpeechInputUnavailable(
              failure: SpeechInputFailure.permissionDenied,
            ),
          ),
          isA<ConversationHeardFailure>().having(
            (event) => event.failure,
            'failure',
            SpeechInputFailure.permissionDenied,
          ),
        );
      });

      test('fails as unavailable on unsupported platforms', () async {
        expect(
          await lastEventWhen(const SpeechInputUnavailable()),
          isA<ConversationHeardFailure>().having(
            (event) => event.failure,
            'failure',
            SpeechInputFailure.recognizerUnavailable,
          ),
        );
      });

      test('fails with its own error (a missing model)', () async {
        onListen = () {
          state = SpeechInputError(
            'error_offline_model_missing',
            permanent: true,
            failure: SpeechInputFailure.offlineModelMissing,
            owner: owner,
          );
          return false;
        };
        final heard = collect(recognizer.listen(english));
        await settle();
        expect(
          heard.events.single,
          isA<ConversationHeardFailure>().having(
            (event) => event.failure,
            'failure',
            SpeechInputFailure.offlineModelMissing,
          ),
        );
      });

      test('ends when another session took over', () async {
        expect(
          await lastEventWhen(const SpeechInputListening()),
          const ConversationHeardEnd(),
        );
      });

      test('fails when listening throws', () async {
        onListen = () => throw StateError('broken');
        final heard = collect(recognizer.listen(english));
        await settle();
        expect(
          heard.events.single,
          const ConversationHeardFailure(SpeechInputFailure.unknown),
        );
      });
    });

    group('cancel', () {
      test('stops its session and ends the stream quietly', () async {
        final heard = collect(recognizer.listen(english));
        await settle();
        state = SpeechInputListening(owner: owner);
        await recognizer.cancel();
        verify(service.cancel).called(1);
        results.add(SpeechInputResult('Hi', isFinal: true, owner: owner));
        await settle();
        expect(heard.events, const [ConversationHeardStart()]);
        expect(heard.done(), isTrue);
        // Nothing to cancel any more.
        await recognizer.cancel();
        verifyNever(service.cancel);
      });

      test('stops a session that is still starting', () async {
        final started = Completer<bool>();
        onListen = () => started.future;
        recognizer.listen(english).listen((_) {});
        await settle();
        await recognizer.cancel();
        verify(service.cancel).called(1);
        started.complete(false);
        await settle();
      });

      test("leaves someone else's session alone", () async {
        final heard = collect(recognizer.listen(english));
        await settle();
        state = const SpeechInputListening();
        await recognizer.cancel();
        verifyNever(service.cancel);
        expect(heard.done(), isTrue);
      });
    });

    test('listening again ends the previous utterance', () async {
      final first = collect(recognizer.listen(english));
      await settle();
      final second = collect(recognizer.listen(spanish));
      await settle();
      expect(first.done(), isTrue);
      expect(second.done(), isFalse);
    });

    test('after dispose listening ends at once', () async {
      await recognizer.dispose();
      final heard = collect(recognizer.listen(english));
      await settle();
      expect(heard.done(), isTrue);
      expect(heard.events, isEmpty);
      verifyNever(
        () => service.listen(
          any(),
          owner: any(named: 'owner'),
          detectLanguage: any(named: 'detectLanguage'),
        ),
      );
    });
  });

  test('hearing events compare by value', () {
    // Tear-offs build new (non-const, so not identical) instances.
    final transcribing = [ConversationHeardTranscribing.new][0];
    expect(transcribing(), transcribing());
    expect(transcribing().props, isEmpty);
    final end = [ConversationHeardEnd.new][0];
    expect(end(interrupted: true), isNot(end()));
    expect(end(interrupted: true), end(interrupted: true));
    final speech = [ConversationHeardSpeech.new][0];
    expect(speech(), speech());
  });

  group('with the app-wide service', () {
    late FakeSpeechRecognizer system;
    late SpeechInputService service;

    setUp(() {
      system = FakeSpeechRecognizer();
      service = SpeechInputService(
        store: MemoryStore(),
        adapter: system,
        platformSupported: true,
      );
    });

    tearDown(() => service.dispose());

    test('hears one utterance in the language asked for', () async {
      final recognizer = SpeechInputConversationRecognizer(service);
      final events = <ConversationHearing>[];
      recognizer.listen(english).listen(events.add);
      await settle();
      expect(system.lastRequest.localeId, 'en_US');
      system.emitResult('Good');
      await settle();
      system.emitResult('Good morning', isFinal: true);
      await settle();
      expect(events, const [
        ConversationHeardStart(),
        ConversationHeardPartial('Good'),
        ConversationHeardSpeech(),
        ConversationHeardFinal('Good morning'),
      ]);
      expect(service.state, const SpeechInputIdle());
    });

    test('hears the final result Android delivers after it stopped '
        'listening', () async {
      final recognizer = SpeechInputConversationRecognizer(service);
      final events = <ConversationHearing>[];
      recognizer.listen(english).listen(events.add);
      await settle();
      system.emitResult('Good');
      await settle();
      system.emitStatus(SpeechRecognizerStatus.notListening);
      await settle();
      expect(service.state, const SpeechInputIdle());
      system.emitResult('Good morning', isFinal: true);
      await settle();
      expect(events, const [
        ConversationHeardStart(),
        ConversationHeardPartial('Good'),
        ConversationHeardSpeech(),
        ConversationHeardFinal('Good morning'),
      ]);
    });

    test('a hands-free conversation waits for that late result', () async {
      final repository = MockTranslationRepository();
      final speech = MockSpeechService();
      final speaking = stubSpeech(speech);
      addTearDown(speaking.close);
      when(() => repository.translate(any(), any()))
          .thenAnswer((_) => Stream.value(resultOf('Buenos días')));
      final timers = FakeTimers();
      final cubit = ConversationCubit(
        repository: repository,
        speech: speech,
        engine: () => deepl,
        languageA: english,
        languageB: spanish,
        recognizer: SpeechInputConversationRecognizer(
          service,
          timer: timers.call,
        ),
        timer: timers.call,
      );
      addTearDown(cubit.close);
      cubit
        ..setAutoSpeak(enabled: false)
        ..startSession();
      await settle();
      system.emitResult('Good');
      await settle();
      system.emitStatus(SpeechRecognizerStatus.notListening);
      await settle();
      // Not listened again: that would drop the late result.
      expect(system.requests, hasLength(1));
      expect(cubit.state.session, isA<ConversationSessionListening>());
      system.emitResult('Good morning', isFinal: true);
      await settle();
      expect(cubit.state.turns.single.original, 'Good morning');
      expect(cubit.state.turns.single.translation, 'Buenos días');
    });

    test('reports silence as no match', () async {
      final recognizer = SpeechInputConversationRecognizer(service);
      final events = <ConversationHearing>[];
      recognizer.listen(english).listen(events.add);
      await settle();
      system.emitError('error_no_match');
      await settle();
      expect(
        events.last,
        isA<ConversationHeardFailure>().having(
          (event) => event.failure,
          'failure',
          SpeechInputFailure.noMatch,
        ),
      );
    });
  });

  group('speechInputConversationRecognizer', () {
    Future<ConversationRecognizer?> build(
      WidgetTester tester, {
      SpeechInputService? service,
    }) async {
      ConversationRecognizer? created;
      final probe = Builder(
        builder: (context) {
          created = speechInputConversationRecognizer(context);
          return const SizedBox();
        },
      );
      await tester.pumpWidget(
        service == null
            ? probe
            : RepositoryProvider<SpeechInputService>.value(
                value: service,
                child: probe,
              ),
      );
      return created;
    }

    testWidgets('uses the app-wide service where speech is supported', (
      tester,
    ) async {
      final service = SpeechInputService(
        store: MemoryStore(),
        adapter: FakeSpeechRecognizer(),
        platformSupported: true,
      );
      addTearDown(service.dispose);
      expect(
        await build(tester, service: service),
        isA<SpeechInputConversationRecognizer>(),
      );
    });

    testWidgets('is null where speech is not supported', (tester) async {
      final service = SpeechInputService(
        store: MemoryStore(),
        adapter: FakeSpeechRecognizer(),
        platformSupported: false,
      );
      addTearDown(service.dispose);
      expect(await build(tester, service: service), isNull);
    });

    testWidgets('is null without the service', (tester) async {
      expect(await build(tester), isNull);
    });
  });
}
