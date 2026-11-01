import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

const _offline = TranslationEngine(
  id: TranslationEngine.offlineId,
  kind: EngineKind.offline,
  name: 'Offline',
  isLocal: true,
);

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;
  setUp(() => mocks = TranslateMocks());

  /// The translation in flight of a test that drives it by hand.
  late StreamController<TranslationResult> results;

  TranslateCubit production() => TranslateCubit(
    repository: mocks.repository,
    settings: mocks.settings,
    history: mocks.history,
    deviceLanguages: () => const [],
  );

  group('instantDelay', () {
    late TranslateCubit cubit;
    setUp(() => cubit = production());
    tearDown(() => cubit.close());

    Duration delay(
      TranslationEngine engine,
      String previous,
      String next, {
      bool pasted = false,
      bool dictated = false,
    }) => cubit.instantDelay(
      engine,
      previous,
      next,
      pasted: pasted,
      dictated: dictated,
    );

    test('has the documented defaults', () {
      expect(cubit.debounce, const Duration(milliseconds: 600));
      expect(cubit.aiDebounce, const Duration(milliseconds: 1200));
      expect(cubit.boundaryDebounce, const Duration(milliseconds: 350));
      expect(cubit.aiBoundaryDebounce, const Duration(milliseconds: 600));
      expect(cubit.aiSentenceDebounce, const Duration(milliseconds: 300));
      expect(cubit.offlineDebounce, const Duration(milliseconds: 250));
    });

    test('never waits longer than the mid-word delays', () {
      final quick = TranslateCubit(
        repository: mocks.repository,
        settings: mocks.settings,
        history: mocks.history,
        debounce: const Duration(milliseconds: 100),
        aiDebounce: const Duration(milliseconds: 200),
      );
      addTearDown(quick.close);
      expect(quick.boundaryDebounce, const Duration(milliseconds: 100));
      expect(quick.aiBoundaryDebounce, const Duration(milliseconds: 200));
      expect(quick.aiSentenceDebounce, const Duration(milliseconds: 200));
    });

    test('a paste goes at once, for every engine', () {
      expect(delay(claude, '', 'Where is the station?'), Duration.zero);
      expect(delay(google, 'Hi', 'Hi there you'), Duration.zero);
      expect(delay(claude, '', 'Hallo', pasted: true), Duration.zero);
      // Dictation is never a paste.
      expect(
        delay(claude, '', 'Where is the ', dictated: true),
        cubit.aiBoundaryDebounce,
      );
    });

    test('the end of a sentence: machine at once, AI after a moment', () {
      expect(delay(google, 'Hello', 'Hello.'), Duration.zero);
      expect(delay(claude, 'Hello', 'Hello.'), cubit.aiSentenceDebounce);
      expect(delay(_offline, 'Hallo', 'Hallo!'), Duration.zero);
      for (final end in ['。', '？', '！', '…', '؟', '۔', '।', '॥']) {
        expect(delay(google, 'x', 'x$end'), Duration.zero, reason: end);
      }
      // Before closing quotes too.
      expect(delay(google, 'He said "Hi', 'He said "Hi."'), Duration.zero);
      // Closing the quote after the full stop ends no new sentence.
      expect(
        delay(google, 'He said "Hi.', 'He said "Hi."'),
        cubit.boundaryDebounce,
      );
      // A second full stop is no new sentence.
      expect(delay(google, 'Hello.', 'Hello..'), cubit.boundaryDebounce);
    });

    test('the DeepL API waits like AI: it is billed by the character', () {
      expect(delay(deeplApi, '', 'Wie geht es dir?'), Duration.zero);
      expect(
        delay(deeplApi, 'Wie geht', 'Wie geht?'),
        cubit.aiSentenceDebounce,
      );
      expect(delay(deeplApi, 'Wie', 'Wie '), cubit.aiBoundaryDebounce);
      expect(delay(deeplApi, 'Wi', 'Wie'), cubit.debounce);
    });

    test('Enter is like the end of a sentence', () {
      expect(delay(google, 'Line', 'Line\n'), Duration.zero);
      expect(delay(claude, 'Line', 'Line\n'), cubit.aiSentenceDebounce);
    });

    test('after a word: short; within a word: as before', () {
      expect(delay(google, 'Hello', 'Hello '), cubit.boundaryDebounce);
      expect(delay(google, 'Hello', 'Hello,'), cubit.boundaryDebounce);
      expect(delay(google, 'Hell', 'Hello'), cubit.debounce);
      expect(delay(claude, 'Hello', 'Hello '), cubit.aiBoundaryDebounce);
      expect(delay(claude, 'Hell', 'Hello'), cubit.aiDebounce);
      expect(delay(_offline, 'Hell', 'Hello'), cubit.offlineDebounce);
      expect(delay(_offline, 'Hello', 'Hello '), cubit.offlineDebounce);
    });

    test('isPasteLike tells pastes from typing', () {
      expect(TranslateCubit.isPasteLike('', 'H'), isFalse);
      expect(TranslateCubit.isPasteLike('Hello', 'Hello '), isFalse);
      // A swiped word or a suggestion is one word.
      expect(TranslateCubit.isPasteLike('Hello', 'Hello world '), isFalse);
      expect(TranslateCubit.isPasteLike('teh', 'the'), isFalse);
      expect(TranslateCubit.isPasteLike('', 'two words'), isTrue);
      expect(TranslateCubit.isPasteLike('', 'Donaudampfschiff'), isTrue);
      // Replacing a selection with pasted text.
      expect(
        TranslateCubit.isPasteLike('Hello', 'Bonjour tout le monde'),
        isTrue,
      );
      expect(TranslateCubit.isPasteLike('a b', 'a'), isFalse);
    });

    test('endsSentence', () {
      expect(TranslateCubit.endsSentence('Hi.'), isTrue);
      expect(TranslateCubit.endsSentence('Hi.)'), isTrue);
      expect(TranslateCubit.endsSentence('Hi. '), isFalse);
      expect(TranslateCubit.endsSentence('Hi'), isFalse);
      expect(TranslateCubit.endsSentence(''), isFalse);
    });
  });

  group('typing', () {
    blocTest<TranslateCubit, TranslateState>(
      'queues the instant translation and keeps the previous result',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(
        input: 'Hallo',
        result: resultOf('Hallo->en'),
        status: TranslateStatus.success,
      ),
      act: (cubit) async {
        cubit.setInput('Hallo Wel');
        expect(cubit.state.queued, isTrue);
        expect(cubit.state.isPending, isTrue);
        // The old result stays, dimmed as stale.
        expect(cubit.state.output, 'Hallo->en');
        expect(cubit.state.isResultStale, isTrue);
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(cubit.state.queued, isFalse);
        expect(cubit.state.isPending, isFalse);
        expect(cubit.state.output, 'Hallo Wel->en');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'nothing is queued without instant translation',
      setUp: () =>
          mocks.stubSettings(const AppSettings(instantTranslate: false)),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.setInput('Hallo'),
      verify: (cubit) => expect(cubit.state.queued, isFalse),
    );

    blocTest<TranslateCubit, TranslateState>(
      'clearing and stopping end the queue',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) {
        cubit.setInput('Hallo');
        expect(cubit.state.queued, isTrue);
        cubit.stopTranslation();
        expect(cubit.state.queued, isFalse);
        cubit.setInput('Hallo Welt');
        expect(cubit.state.queued, isTrue);
        cubit.clear();
        expect(cubit.state.queued, isFalse);
      },
      verify: (_) =>
          verifyNever(() => mocks.repository.translate(any(), any())),
    );

    blocTest<TranslateCubit, TranslateState>(
      'a queue whose engine went away ends without a translation',
      setUp: () {
        when(() => mocks.repository.getEngines(refresh: any(named: 'refresh')))
            .thenAnswer((_) async => const []);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('Hallo');
        await cubit.loadEngines();
        expect(cubit.state.engine, isNull);
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(cubit.state.queued, isFalse);
        verifyNever(() => mocks.repository.translate(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a paste is translated at once, also by AI engines',
      setUp: () => mocks.stubTranslate(),
      build: () => TranslateCubit(
        repository: mocks.repository,
        settings: mocks.settings,
        history: mocks.history,
      ),
      seed: () => readyState(engine: claude),
      act: (cubit) async {
        cubit.setInput('Hallo', pasted: true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (cubit) {
        expect(mocks.translateRequests().single.text, 'Hallo');
        expect(cubit.state.output, 'Hallo->en');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'white space typed after a translation sends nothing again',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('Hallo.');
        await Future<void>.delayed(afterDebounce);
        cubit.setInput('Hallo. ');
        expect(cubit.state.queued, isFalse);
        expect(cubit.state.isResultStale, isFalse);
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        expect(mocks.translateRequests().map((r) => r.text), ['Hallo.']);
        expect(cubit.state.output, 'Hallo.->en');
        expect(cubit.state.resultInput, 'Hallo. ');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'white space typed during a translation keeps its result current',
      setUp: () {
        results = StreamController<TranslationResult>();
        addTearDown(results.close);
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => results.stream);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        unawaited(cubit.translate());
        cubit.setInput('Hallo ');
        expect(cubit.state.queued, isFalse);
        results.add(resultOf('Hel', isComplete: false));
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.resultInput, 'Hallo ');
        results.add(resultOf('Hello'));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        verify(() => mocks.repository.translate(any(), any())).called(1);
        expect(cubit.state.output, 'Hello');
        expect(cubit.state.isResultStale, isFalse);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a failure keeps the part translated before white space was typed',
      setUp: () {
        when(() => mocks.repository.translate(any(), any())).thenAnswer((_) {
          final controller = StreamController<TranslationResult>();
          scheduleMicrotask(() {
            controller
              ..add(resultOf('Hel', isComplete: false))
              ..addError(Exception('down'));
            unawaited(controller.close());
          });
          return controller.stream;
        });
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo Welt'),
      act: (cubit) async {
        unawaited(cubit.translate());
        cubit.setInput('Hallo Welt ');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      verify: (cubit) {
        expect(cubit.state.status, TranslateStatus.failure);
        expect(cubit.state.output, 'Hel');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a translation of the input drops its queued instant translation',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('Hallo');
        await cubit.translate();
        expect(cubit.state.queued, isFalse);
        await Future<void>.delayed(afterDebounce);
      },
      verify: (_) =>
          verify(() => mocks.repository.translate(any(), any())).called(1),
    );

    // The production delays, with time under the test's control.
    for (final (name, text) in [
      ('one sentence', 'Where is the train station?'),
      ('two sentences', 'Hi there. Where is the train station?'),
      ('a new line', 'Dear Anna,\nsee you tomorrow!'),
    ]) {
      testWidgets(
        'typing $name at a normal pace asks an AI engine once, as before',
        (tester) async {
          mocks.stubTranslate();
          final cubit = production()..emit(readyState(engine: claude));
          addTearDown(cubit.close);
          // A key every 150 ms, a little longer after each word.
          for (var i = 1; i <= text.length; i++) {
            cubit.setInput(text.substring(0, i));
            final key = text[i - 1];
            await tester.pump(
              Duration(milliseconds: key == ' ' || key == '\n' ? 250 : 150),
            );
          }
          await tester.pump(const Duration(seconds: 2));
          expect(mocks.translateRequests().map((r) => r.text), [text]);
        },
      );
    }

    testWidgets('a pause after a word sends at most one request sooner', (
      tester,
    ) async {
      mocks.stubTranslate();
      final cubit = production()..emit(readyState(engine: claude));
      addTearDown(cubit.close);
      cubit.setInput('Hello ');
      await tester.pump(const Duration(milliseconds: 650));
      expect(mocks.translateRequests().map((r) => r.text), ['Hello ']);
      cubit.setInput('Hello w');
      await tester.pump(const Duration(milliseconds: 650));
      // Mid-word: still waiting.
      verifyNever(() => mocks.repository.translate(any(), any()));
      await tester.pump(const Duration(milliseconds: 600));
      expect(mocks.translateRequests().map((r) => r.text), ['Hello w']);
    });
  });

  group('quality modes', () {
    blocTest<TranslateCubit, TranslateState>(
      'a saved "usual engine" moves to Fast once both are set up',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          engineId: 'mozhi:deepl',
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
        ),
      ),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.fast);
        expect(cubit.state.engine, google);
        expect(cubit.state.hasQualityModes, isTrue);
        expect(cubit.state.availableQualityModes, [
          QualityMode.fast,
          QualityMode.best,
        ]);
        verify(() => mocks.settings.setQualityMode(QualityMode.fast)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a usual engine that is the Best one moves to Best',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          engineId: 'ai:claude',
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
        ),
      ),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.best);
        expect(cubit.state.engine, claude);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a mode without an engine of its own uses the usual engine',
      setUp: () => mocks.stubSettings(
        const AppSettings(engineId: 'mozhi:deepl', bestEngineId: 'ai:claude'),
      ),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.fastEngine, deepl);
        expect(cubit.state.bestEngine, claude);
        expect(cubit.state.qualityMode, QualityMode.fast);
        // Nothing changed for the user: Fast is the usual engine.
        expect(cubit.state.engine, deepl);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'without a saved engine the usual one is the default engine',
      setUp: () =>
          mocks.stubSettings(const AppSettings(bestEngineId: 'ai:claude')),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.fastEngine, google);
        expect(cubit.state.qualityMode, QualityMode.fast);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'one engine for both modes is no choice: not set up',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          engineId: 'mozhi:google',
          fastEngineId: 'mozhi:google',
        ),
      ),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.fastEngine, google);
        expect(cubit.state.bestEngine, isNull);
        expect(cubit.state.hasQualityModes, isFalse);
        expect(cubit.state.qualityMode, QualityMode.off);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a configured engine that is gone is not replaced by the usual one',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          fastEngineId: 'mozhi:gone',
          bestEngineId: 'ai:claude',
        ),
      ),
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      verify: (cubit) {
        expect(cubit.state.fastEngine, isNull);
        expect(cubit.state.hasQualityModes, isFalse);
      },
    );

    TranslateState setUpState({
      QualityMode mode = QualityMode.fast,
      String input = '',
    }) =>
        readyState(
          engine: mode == QualityMode.best ? claude : google,
          input: input,
        ).copyWith(
          qualityMode: mode,
          fastEngine: () => google,
          bestEngine: () => claude,
        );

    blocTest<TranslateCubit, TranslateState>(
      'picking an engine makes it the engine of the active mode',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubSettings(
            const AppSettings(
              fastEngineId: 'mozhi:google',
              bestEngineId: 'ai:claude',
              qualityMode: QualityMode.fast,
            ),
          );
      },
      build: () => mocks.build(),
      seed: () => setUpState(input: 'Hallo'),
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.fast);
        expect(cubit.state.fastEngine, deepl);
        verify(
          () => mocks.settings.setQualityEngines(
            fast: 'mozhi:deepl',
            best: 'ai:claude',
          ),
        ).called(1);
        verifyNever(() => mocks.settings.setEngine(any()));
        verifyNever(() => mocks.settings.setQualityMode(QualityMode.off));
        verify(() => mocks.repository.translate(deepl, any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'picking an engine for Best',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      seed: () => setUpState(mode: QualityMode.best),
      act: (cubit) => cubit.selectEngine(local),
      verify: (cubit) {
        expect(cubit.state.bestEngine, local);
        verify(
          () => mocks.settings.setQualityEngines(
            fast: 'mozhi:google',
            best: 'ai:local',
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      "picking the other mode's engine selects that mode",
      setUp: () => mocks.stubSettings(
        const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.fast,
        ),
      ),
      build: () => mocks.build(),
      seed: setUpState,
      act: (cubit) => cubit.selectEngine(claude),
      verify: (cubit) {
        expect(cubit.state.engine, claude);
        expect(cubit.state.qualityMode, QualityMode.best);
        verify(() => mocks.settings.setQualityMode(QualityMode.best)).called(1);
        verifyNever(
          () => mocks.settings.setQualityEngines(
            fast: any(named: 'fast'),
            best: any(named: 'best'),
          ),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a mode on the usual engine makes the pick the usual engine',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          engineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.fast,
        ),
      ),
      build: () => mocks.build(),
      seed: setUpState,
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.fast);
        verify(() => mocks.settings.setEngine('mozhi:deepl')).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      "picking the mode's own engine changes nothing",
      setUp: () => mocks.stubSettings(
        const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.fast,
        ),
      ),
      build: () => mocks.build(),
      seed: setUpState,
      act: (cubit) => cubit.selectEngine(google),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.fast);
        verifyNever(() => mocks.settings.setEngine(any()));
        verifyNever(() => mocks.repository.getSourceLanguages(any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      '"standard" (off) means Fast once the modes are set up',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.best,
        ),
      ),
      build: () => mocks.build(),
      seed: () => setUpState(mode: QualityMode.best),
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.fast);
        expect(cubit.state.engine, google);
      },
    );

    group('settings changes', () {
      late StreamController<AppSettings> settings;

      setUp(() {
        settings = StreamController<AppSettings>();
        addTearDown(settings.close);
        when(() => mocks.settings.stream).thenAnswer((_) => settings.stream);
      });

      blocTest<TranslateCubit, TranslateState>(
        'turn a mode on when Fast and Best become set up',
        build: () => mocks.build(),
        seed: readyState,
        act: (cubit) async {
          const both = AppSettings(
            engineId: 'mozhi:google',
            fastEngineId: 'mozhi:deepl',
            bestEngineId: 'ai:claude',
          );
          mocks.stubSettings(both);
          settings.add(both);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
        verify: (cubit) {
          expect(cubit.state.fastEngine, deepl);
          expect(cubit.state.bestEngine, claude);
          expect(cubit.state.qualityMode, QualityMode.fast);
          expect(cubit.state.engine, deepl);
          verify(() => mocks.settings.setQualityMode(QualityMode.fast))
              .called(1);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'other settings leave the mode alone',
        build: () => mocks.build(),
        seed: setUpState,
        act: (cubit) async {
          const same = AppSettings(
            fastEngineId: 'mozhi:google',
            bestEngineId: 'ai:claude',
            qualityMode: QualityMode.fast,
            instantTranslate: false,
          );
          mocks.stubSettings(same);
          settings.add(same);
          await Future<void>.delayed(Duration.zero);
        },
        verify: (cubit) {
          expect(cubit.state.qualityMode, QualityMode.fast);
          expect(cubit.state.engine, google);
        },
      );
    });

    blocTest<TranslateCubit, TranslateState>(
      "using another engine's compare result makes it the mode's engine",
      setUp: () => mocks.stubSettings(
        const AppSettings(
          fastEngineId: 'mozhi:google',
          bestEngineId: 'ai:claude',
          qualityMode: QualityMode.fast,
        ),
      ),
      build: () => mocks.build(),
      seed: () => setUpState(input: 'Hallo').copyWith(compareMode: true),
      act: (cubit) async {
        cubit.useCompareEntry(
          CompareEntry.success(resultOf('Hello', engine: deepl)),
        );
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.engine, deepl);
        expect(cubit.state.qualityMode, QualityMode.fast);
        expect(cubit.state.output, 'Hello');
        verify(
          () => mocks.settings.setQualityEngines(
            fast: 'mozhi:deepl',
            best: 'ai:claude',
          ),
        ).called(1);
      },
    );
  });

  group('quality modes that are not set up', () {
    /// Only a Fast engine (DeepL), so no toggle.
    TranslateState fastOnly({
      QualityMode mode = QualityMode.off,
      TranslationEngine engine = google,
      String input = '',
    }) => readyState(
      engine: engine,
      input: input,
    ).copyWith(qualityMode: mode, fastEngine: () => deepl);

    blocTest<TranslateCubit, TranslateState>(
      'a link can still turn the mode on, remembering the engine in use',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => fastOnly(input: 'Hallo'),
      act: (cubit) => cubit.setQualityMode(QualityMode.fast, persist: false),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.fast);
        expect(cubit.state.engine, deepl);
        // The engine in use becomes the usual one to go back to.
        verify(() => mocks.settings.setEngine('mozhi:google')).called(1);
        verifyNever(() => mocks.settings.setQualityMode(any()));
        verify(() => mocks.repository.translate(deepl, any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'turning it off returns to an engine that is not a cloud provider',
      build: () => mocks.build(),
      seed: () => fastOnly(mode: QualityMode.fast, engine: deepl),
      act: (cubit) => cubit.setQualityMode(QualityMode.off),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.off);
        expect(cubit.state.engine, google);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'picking the engine in use leaves the mode and saves it',
      setUp: () => mocks.stubSettings(
        const AppSettings(
          fastEngineId: 'mozhi:deepl',
          qualityMode: QualityMode.fast,
        ),
      ),
      build: () => mocks.build(),
      seed: () => fastOnly(mode: QualityMode.fast, engine: deepl),
      act: (cubit) => cubit.selectEngine(deepl),
      verify: (cubit) {
        expect(cubit.state.qualityMode, QualityMode.off);
        verify(() => mocks.settings.setQualityMode(QualityMode.off)).called(1);
        verify(() => mocks.settings.setEngine('mozhi:deepl')).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a mode whose engine fails to load falls back to the other mode',
      setUp: () {
        mocks.stubSettings(
          const AppSettings(
            engineId: 'mozhi:google',
            fastEngineId: 'mozhi:google',
            bestEngineId: 'ai:claude',
            qualityMode: QualityMode.best,
          ),
        );
        when(() => mocks.repository.getSourceLanguages(claude))
            .thenThrow(Exception('down'));
      },
      build: () => mocks.build(),
      act: (cubit) => cubit.loadEngines(),
      errors: () => [isA<Exception>()],
      verify: (cubit) {
        expect(cubit.state.engine, google);
        expect(cubit.state.qualityMode, QualityMode.fast);
      },
    );

    group('settings changes', () {
      late StreamController<AppSettings> settings;

      setUp(() {
        settings = StreamController<AppSettings>();
        addTearDown(settings.close);
        when(() => mocks.settings.stream).thenAnswer((_) => settings.stream);
      });

      blocTest<TranslateCubit, TranslateState>(
        'removing the engines turns the mode off',
        build: () => mocks.build(),
        seed: () => readyState().copyWith(
          qualityMode: QualityMode.fast,
          fastEngine: () => google,
          bestEngine: () => claude,
        ),
        act: (cubit) async {
          const none = AppSettings(engineId: 'mozhi:deepl');
          mocks.stubSettings(none);
          settings.add(none);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
        verify: (cubit) {
          expect(cubit.state.hasQualityModes, isFalse);
          expect(cubit.state.qualityMode, QualityMode.off);
          expect(cubit.state.engine, deepl);
          verify(() => mocks.settings.setQualityMode(QualityMode.off))
              .called(1);
        },
      );
    });
  });

  group('compare', () {
    final current = resultOf('Hello');

    /// The input translated by Google into English (a finished result of
    /// the current languages).
    Future<void> translated(TranslateCubit cubit) async {
      when(() => mocks.repository.translate(any(), any()))
          .thenAnswer((_) => Stream.value(current));
      await cubit.translate();
    }

    void stubCompare(List<CompareEntry> entries) {
      when(() => mocks.repository.compare(any(), any()))
          .thenAnswer((_) => Stream.fromIterable(entries));
    }

    blocTest<TranslateCubit, TranslateState>(
      'choosing Compare compares at once, from the current translation',
      setUp: () => stubCompare([
        CompareEntry.success(resultOf('Hallo', engine: claude)),
        CompareEntry.success(resultOf('Hello', engine: deepl)),
      ]),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await translated(cubit);
        cubit.setCompareMode(enabled: true);
        expect(cubit.state.compareBaseline, current);
        expect(cubit.state.comparing, isTrue);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        final engines =
            verify(() => mocks.repository.compare(captureAny(), any()))
                    .captured
                    .single
                as List<TranslationEngine>;
        // Google translated already: it is not asked again.
        expect(engines, [deepl, claude]);
        // Ordered by engine, not by arrival.
        expect(cubit.state.compareEntries.map((e) => e.id), [
          'mozhi:google',
          'mozhi:deepl',
          'ai:claude',
        ]);
        expect(cubit.state.comparing, isFalse);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a result into another language is no baseline',
      setUp: () => stubCompare(const []),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await translated(cubit);
        cubit.setCompareMode(enabled: true);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.compareBaseline, current);
        // Compares again into German; the result is into English.
        cubit.setTarget(de);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.compareBaseline, isNull);
      },
      verify: (cubit) {
        final calls = verify(
          () => mocks.repository.compare(captureAny(), any()),
        ).captured;
        expect(calls.last, allEngines);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a result from the history is no baseline',
      setUp: () {
        stubCompare(const []);
        mocks.stubHistory([
          HistoryEntry(
            id: '1',
            text: 'Hallo',
            translation: 'Hello',
            source: Language.auto,
            target: en,
            engineId: google.id,
            engineName: google.name,
            createdAt: DateTime.now(),
          ),
        ]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) {
        cubit
          ..setInput('Hallo')
          ..useMemoryMatch()
          ..setCompareMode(enabled: true);
      },
      verify: (cubit) {
        expect(cubit.state.compareBaseline, isNull);
        final engines =
            verify(() => mocks.repository.compare(captureAny(), any()))
                    .captured
                    .single
                as List<TranslationEngine>;
        expect(engines, allEngines);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'without input nothing is compared',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.setCompareMode(enabled: true),
      verify: (cubit) {
        expect(cubit.state.compareMode, isTrue);
        verifyNever(() => mocks.repository.compare(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'only the baseline engine: nothing to ask',
      setUp: () => mocks.stubSettings(
        const AppSettings(compareEngineIds: ['mozhi:google']),
      ),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await translated(cubit);
        await cubit.runCompare();
      },
      verify: (cubit) {
        expect(cubit.state.compareEntries, [CompareEntry.success(current)]);
        expect(cubit.state.comparing, isFalse);
        verifyNever(() => mocks.repository.compare(any(), any()));
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'using the current translation just leaves compare mode',
      setUp: () => stubCompare(const []),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await translated(cubit);
        cubit.setCompareMode(enabled: true);
        await Future<void>.delayed(Duration.zero);
        cubit.useCompareEntry(cubit.state.compareEntries.first);
      },
      verify: (cubit) {
        expect(cubit.state.compareMode, isFalse);
        expect(cubit.state.compareBaseline, isNull);
        expect(cubit.state.result, current);
        // Recorded once, by the translation.
        verify(() => mocks.history.add(any())).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'an edit drops the baseline',
      setUp: () => stubCompare(const []),
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await translated(cubit);
        cubit.setCompareMode(enabled: true);
        await Future<void>.delayed(Duration.zero);
        cubit.setInput('Hallo Welt');
      },
      verify: (cubit) {
        expect(cubit.state.compareEntries, isEmpty);
        expect(cubit.state.compareBaseline, isNull);
      },
    );
  });

  group('openHistoryEntry', () {
    const chinese = Language(code: 'zh-CN', name: 'Chinese (Simplified)');

    HistoryEntry entry({
      Language source = fr,
      Language target = de,
      HistoryEntryKind kind = HistoryEntryKind.translation,
      String text = 'Où est la gare ?',
    }) => HistoryEntry(
      id: '1',
      text: text,
      translation: 'Wo ist der Bahnhof?',
      source: source,
      target: target,
      engineId: google.id,
      engineName: google.name,
      createdAt: DateTime(2026, 10, 20),
      kind: kind,
    );

    blocTest<TranslateCubit, TranslateState>(
      'sets the languages and the text at once and translates once',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'old text', target: es),
      act: (cubit) => cubit.openHistoryEntry(entry()),
      wait: afterDebounce,
      verify: (cubit) {
        final request = mocks.translateRequests().single;
        expect(request.text, 'Où est la gare ?');
        expect(request.source, fr);
        expect(request.target, de);
        expect(cubit.state.output, 'Où est la gare ?->de');
        verify(() => mocks.settings.setLanguages(source: fr)).called(1);
        verify(() => mocks.settings.setLanguages(target: de)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      "maps the languages onto the engine's lists",
      setUp: () {
        mocks.stubTranslate();
        when(() => mocks.repository.getTargetLanguages(any()))
            .thenAnswer((_) async => [...targets, chinese]);
      },
      build: () => mocks.build(),
      seed: () =>
          readyState(source: de)
              .copyWith(targetLanguages: [...targets, chinese]),
      act: (cubit) => cubit.openHistoryEntry(
        entry(
          source: const Language(code: 'EN', name: 'English'),
          target: const Language(code: 'zh', name: 'Chinese'),
        ),
      ),
      wait: afterDebounce,
      verify: (cubit) {
        expect(cubit.state.source, en);
        expect(cubit.state.target, chinese);
        final request = mocks.translateRequests().single;
        expect(request.source, en);
        expect(request.target.code, 'zh-CN');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps a language the engine does not offer',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(source: de),
      act: (cubit) => cubit.openHistoryEntry(entry(source: ja, target: pirate)),
      wait: afterDebounce,
      verify: (cubit) {
        expect(cubit.state.source, de);
        expect(cubit.state.target, en);
        expect(mocks.translateRequests().single.text, 'Où est la gare ?');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits the new languages and text in one state',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => readyState(input: 'old text', target: es),
      act: (cubit) => cubit.openHistoryEntry(entry()),
      wait: afterDebounce,
      verify: (cubit) {},
      expect: () => [
        isA<TranslateState>()
            .having((s) => s.source, 'source', fr)
            .having((s) => s.target, 'target', de)
            .having((s) => s.input, 'input', 'Où est la gare ?'),
        isA<TranslateState>().having(
          (s) => s.status,
          'status',
          TranslateStatus.translating,
        ),
        isA<TranslateState>().having(
          (s) => s.status,
          'status',
          TranslateStatus.success,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores look-ups and empty entries',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit
        ..openHistoryEntry(entry(kind: HistoryEntryKind.dictionary))
        ..openHistoryEntry(entry(text: '  ')),
      expect: () => <TranslateState>[],
    );
  });

  group('restoreHistoryEntry', () {
    HistoryEntry entry({
      Language source = Language.auto,
      Language target = de,
      HistoryEntryKind kind = HistoryEntryKind.translation,
      String text = 'Where is the station?',
    }) => HistoryEntry(
      id: '1',
      text: text,
      translation: 'Wo ist der Bahnhof?',
      source: source,
      target: target,
      engineId: deepl.id,
      engineName: deepl.name,
      createdAt: DateTime(2026, 10, 20),
      detectedSource: 'en',
      kind: kind,
    );

    blocTest<TranslateCubit, TranslateState>(
      'shows the entry again without asking an engine',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => expect(cubit.restoreHistoryEntry(entry()), isTrue),
      verify: (cubit) {
        final state = cubit.state;
        expect(state.input, 'Where is the station?');
        expect(state.target, de);
        expect(state.source, Language.auto);
        expect(state.output, 'Wo ist der Bahnhof?');
        expect(state.result?.engineName, 'DeepL');
        expect(state.result?.detectedSource, 'en');
        expect(state.resultFromMemory, isTrue);
        expect(state.instantResult, isTrue);
        expect(state.isResultStale, isFalse);
        expect(state.queued, isFalse);
        verifyNever(() => mocks.repository.translate(any(), any()));
        verifyNever(() => mocks.history.add(any()));
        verify(() => mocks.settings.setLanguages(target: de)).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'restores a chosen source language',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.restoreHistoryEntry(entry(source: fr)),
      verify: (cubit) => expect(cubit.state.source, fr),
    );

    blocTest<TranslateCubit, TranslateState>(
      'cuts text longer than the input takes',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.restoreHistoryEntry(
        entry(text: 'a' * (TranslateCubit.maxInputLength + 5)),
      ),
      verify: (cubit) {
        expect(cubit.state.input.length, TranslateCubit.maxInputLength);
        expect(cubit.state.inputTruncated, isTrue);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'refuses what it cannot show',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) {
        expect(
          cubit.restoreHistoryEntry(entry(kind: HistoryEntryKind.dictionary)),
          isFalse,
        );
        expect(cubit.restoreHistoryEntry(entry(target: ja)), isFalse);
        expect(cubit.restoreHistoryEntry(entry(source: ja)), isFalse);
        expect(cubit.restoreHistoryEntry(entry(text: '  ')), isFalse);
        cubit.setCompareMode(enabled: true);
        expect(cubit.restoreHistoryEntry(entry()), isFalse);
      },
      verify: (cubit) => expect(cubit.state.input, isEmpty),
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs an engine',
      build: () => mocks.build(),
      act: (cubit) => expect(cubit.restoreHistoryEntry(entry()), isFalse),
    );
  });
}
