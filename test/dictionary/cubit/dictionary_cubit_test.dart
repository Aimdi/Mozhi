import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/dictionary_helpers.dart';

void main() {
  setUpAll(registerDictionaryFallbacks);

  late MockTranslationRepository repository;
  late MockUsageTracker tracker;

  setUp(() {
    repository = MockTranslationRepository();
    tracker = MockUsageTracker();
    when(
      () => tracker.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async => UsageStats.zero);
    stubLookUp(repository, () async => gatoEntry);
  });

  DictionaryCubit build({
    TranslationEngine? engine = claudeEngine,
    String word = '',
    Language source = Language.auto,
    Language target = english,
    DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
    UsageTracker? usageTracker,
  }) => DictionaryCubit(
    repository: repository,
    engine: engine,
    word: word,
    source: source,
    target: target,
    verbosity: verbosity,
    uiLanguage: 'German',
    usageTracker: usageTracker,
  );

  void verifyLookUp(
    String word, {
    Language source = Language.auto,
    Language target = english,
    DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
    int times = 1,
  }) => verify(
    () => repository.lookUp(
      claudeEngine,
      word,
      source: source,
      target: target,
      uiLanguage: 'German',
      verbosity: verbosity,
    ),
  ).called(times);

  void verifyNoLookUp() => verifyNever(
    () => repository.lookUp(
      any(),
      any(),
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: any(named: 'verbosity'),
    ),
  );

  group('DictionaryCubit', () {
    test('starts with the given word, languages and engine', () {
      final cubit = build(word: 'gato', source: spanish, target: french);
      expect(
        cubit.state,
        const DictionaryState(
          word: 'gato',
          source: spanish,
          target: french,
          engine: claudeEngine,
        ),
      );
      expect(cubit.state.canLookUp, isTrue);
      expect(cubit.state.canSwap, isTrue);
    });

    test('starts with the standard or the given detail level', () {
      expect(build().state.verbosity, DictionaryVerbosity.standard);
      expect(
        build(verbosity: DictionaryVerbosity.concise).state.verbosity,
        DictionaryVerbosity.concise,
      );
    });

    test('cuts a long word without splitting a surrogate pair', () {
      expect(
        build(word: 'a' * 500).state.word,
        hasLength(DictionaryCubit.maxWordLength),
      );
      final emoji = '${'a' * (DictionaryCubit.maxWordLength - 1)}😀';
      expect(
        build(word: emoji).state.word,
        'a' * (DictionaryCubit.maxWordLength - 1),
      );
    });

    test('never starts with custom or auto target languages', () {
      final cubit = build(
        source: const Language.custom('Pirate speak'),
        target: Language.auto,
      );
      expect(cubit.state.source, Language.auto);
      expect(cubit.state.target, english);
      expect(
        build(target: const Language.custom('Shakespeare')).state.target,
        english,
      );
      expect(cubit.state.canSwap, isFalse);
    });

    test('ignores engines without AI extras', () {
      expect(build(engine: googleEngine).state.engine, isNull);
      expect(build(engine: null).state.hasEngine, isFalse);
      expect(build(engine: null, word: 'x').state.canLookUp, isFalse);
    });

    blocTest<DictionaryCubit, DictionaryState>(
      'looks the word up',
      build: () => build(word: ' gato ', source: spanish),
      act: (cubit) => cubit.lookUp(),
      expect: () => const [
        DictionaryState(
          word: ' gato ',
          source: spanish,
          engine: claudeEngine,
          status: DictionaryStatus.loading,
          lookedUp: 'gato',
        ),
        DictionaryState(
          word: ' gato ',
          source: spanish,
          engine: claudeEngine,
          status: DictionaryStatus.success,
          lookedUp: 'gato',
          entry: gatoEntry,
        ),
      ],
      verify: (_) => verifyLookUp('gato', source: spanish),
    );

    blocTest<DictionaryCubit, DictionaryState>(
      'does nothing without a word',
      build: () => build(word: '  '),
      act: (cubit) => cubit.lookUp(),
      expect: () => const <DictionaryState>[],
      verify: (_) => verifyNever(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          uiLanguage: any(named: 'uiLanguage'),
        ),
      ),
    );

    blocTest<DictionaryCubit, DictionaryState>(
      'reports failures',
      setUp: () => stubLookUp(repository, () async => throw StateError('x')),
      build: () => build(word: 'gato'),
      act: (cubit) => cubit.lookUp(),
      expect: () => [
        isA<DictionaryState>().having(
          (s) => s.status,
          'status',
          DictionaryStatus.loading,
        ),
        isA<DictionaryState>()
            .having((s) => s.status, 'status', DictionaryStatus.failure)
            .having((s) => s.error, 'error', isA<StateError>())
            .having((s) => s.entry, 'entry', isNull),
      ],
      errors: () => [isA<StateError>()],
    );

    blocTest<DictionaryCubit, DictionaryState>(
      'drops a response that a newer look-up superseded',
      setUp: () {
        final slow = Completer<DictionaryEntry>();
        var calls = 0;
        stubLookUp(repository, () {
          calls++;
          return calls == 1 ? slow.future : Future.value(gatoEntry);
        });
        addTearDown(() => slow.complete(const DictionaryEntry(word: 'old')));
      },
      build: () => build(word: 'gato'),
      act: (cubit) async {
        unawaited(cubit.lookUp());
        await cubit.lookUp();
      },
      expect: () => [
        isA<DictionaryState>().having(
          (s) => s.status,
          'status',
          DictionaryStatus.loading,
        ),
        isA<DictionaryState>().having((s) => s.entry, 'entry', gatoEntry),
      ],
    );

    blocTest<DictionaryCubit, DictionaryState>(
      'ignores a response after a clear',
      setUp: () {
        final slow = Completer<DictionaryEntry>();
        stubLookUp(repository, () => slow.future);
        addTearDown(() => slow.complete(gatoEntry));
      },
      build: () => build(word: 'gato'),
      act: (cubit) async {
        unawaited(cubit.lookUp());
        cubit.clear();
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        isA<DictionaryState>().having(
          (s) => s.status,
          'status',
          DictionaryStatus.loading,
        ),
        const DictionaryState(engine: claudeEngine),
      ],
    );

    group('closeEntry', () {
      blocTest<DictionaryCubit, DictionaryState>(
        'goes back to the search, keeping the word',
        build: () => build(word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit.closeEntry();
        },
        skip: 2,
        expect: () => const [
          DictionaryState(word: 'gato', engine: claudeEngine),
        ],
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'ignores the response of the look-up it leaves',
        setUp: () {
          final slow = Completer<DictionaryEntry>();
          stubLookUp(repository, () => slow.future);
          addTearDown(() => slow.complete(gatoEntry));
        },
        build: () => build(word: 'gato'),
        act: (cubit) async {
          unawaited(cubit.lookUp());
          cubit.closeEntry();
          await Future<void>.delayed(Duration.zero);
        },
        expect: () => [
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.loading,
          ),
          const DictionaryState(word: 'gato', engine: claudeEngine),
        ],
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'cancels a look-up waiting for an engine',
        build: () => build(engine: null, word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit
            ..closeEntry()
            ..setEngine(claudeEngine);
        },
        expect: () => const [
          DictionaryState(word: 'gato'),
          DictionaryState(word: 'gato', engine: claudeEngine),
        ],
        verify: (_) => verifyNever(
          () => repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
            uiLanguage: any(named: 'uiLanguage'),
            verbosity: any(named: 'verbosity'),
          ),
        ),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'a language change afterwards does not look up again',
        build: () => build(word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit
            ..closeEntry()
            ..setTarget(french);
        },
        skip: 3,
        expect: () => const [
          DictionaryState(word: 'gato', target: french, engine: claudeEngine),
        ],
      );
    });

    test('ignores a response that arrives after closing', () async {
      final slow = Completer<DictionaryEntry>();
      stubLookUp(repository, () => slow.future);
      final cubit = build(word: 'gato');
      final done = cubit.lookUp();
      await cubit.close();
      slow.complete(gatoEntry);
      await done;
      expect(cubit.state.status, DictionaryStatus.loading);
    });

    test('ignores a failure that arrives after closing', () async {
      final slow = Completer<DictionaryEntry>();
      stubLookUp(repository, () => slow.future);
      final cubit = build(word: 'gato');
      final done = cubit.lookUp();
      await cubit.close();
      slow.completeError(StateError('late'));
      await done;
      expect(cubit.state.status, DictionaryStatus.loading);
    });

    group('without an engine', () {
      blocTest<DictionaryCubit, DictionaryState>(
        'waits for one, then looks the word up',
        build: () => build(engine: null, word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit.setEngine(claudeEngine);
          await Future<void>.delayed(Duration.zero);
        },
        expect: () => [
          const DictionaryState(word: 'gato', engine: claudeEngine),
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.loading,
          ),
          isA<DictionaryState>().having((s) => s.entry, 'entry', gatoEntry),
        ],
        verify: (_) => verifyLookUp('gato'),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'does not look up a word that was edited meanwhile',
        build: () => build(engine: null, word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit
            ..setWord('perro')
            ..setEngine(claudeEngine);
        },
        expect: () => const [
          DictionaryState(word: 'perro'),
          DictionaryState(word: 'perro', engine: claudeEngine),
        ],
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'keeps waiting while engines without AI extras arrive',
        build: () => build(engine: null, word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit.setEngine(googleEngine);
        },
        expect: () => const <DictionaryState>[],
      );
    });

    blocTest<DictionaryCubit, DictionaryState>(
      'setEngine replaces and removes the engine',
      build: build,
      act: (cubit) => cubit
        ..setEngine(ollamaEngine)
        ..setEngine(ollamaEngine)
        ..setEngine(null),
      expect: () => const [
        DictionaryState(engine: ollamaEngine),
        DictionaryState(),
      ],
    );

    blocTest<DictionaryCubit, DictionaryState>(
      'setWord cuts long words and skips unchanged ones',
      build: build,
      act: (cubit) => cubit
        ..setWord('gato')
        ..setWord('gato')
        ..setWord('b' * 300),
      expect: () => [
        const DictionaryState(word: 'gato', engine: claudeEngine),
        DictionaryState(
          word: 'b' * DictionaryCubit.maxWordLength,
          engine: claudeEngine,
        ),
      ],
    );

    group('languages', () {
      blocTest<DictionaryCubit, DictionaryState>(
        'change without a request before anything was looked up',
        build: () => build(word: 'gato'),
        act: (cubit) => cubit
          ..setSource(spanish)
          ..setTarget(french)
          ..setSource(spanish)
          ..setTarget(french),
        expect: () => const [
          DictionaryState(word: 'gato', source: spanish, engine: claudeEngine),
          DictionaryState(
            word: 'gato',
            source: spanish,
            target: french,
            engine: claudeEngine,
          ),
        ],
        verify: (_) => verifyNever(
          () => repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'ignore custom styles and auto targets',
        build: build,
        act: (cubit) => cubit
          ..setSource(const Language.custom('Pirate speak'))
          ..setTarget(const Language.custom('Pirate speak'))
          ..setTarget(Language.auto),
        expect: () => const <DictionaryState>[],
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'look the word up again after a look-up',
        build: () => build(word: 'gato', source: spanish),
        act: (cubit) async {
          await cubit.lookUp();
          cubit.setTarget(french);
          await Future<void>.delayed(Duration.zero);
          cubit.swap();
          await Future<void>.delayed(Duration.zero);
          cubit.setSource(english);
          await Future<void>.delayed(Duration.zero);
        },
        skip: 2,
        expect: () => [
          isA<DictionaryState>().having((s) => s.target, 'target', french),
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.loading,
          ),
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.success,
          ),
          isA<DictionaryState>()
              .having((s) => s.source, 'source', french)
              .having((s) => s.target, 'target', spanish),
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.loading,
          ),
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.success,
          ),
          isA<DictionaryState>().having((s) => s.source, 'source', english),
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.loading,
          ),
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.success,
          ),
        ],
        verify: (_) {
          verifyLookUp('gato', source: spanish);
          verifyLookUp('gato', source: spanish, target: french);
          verifyLookUp('gato', source: french, target: spanish);
          verifyLookUp('gato', source: english, target: spanish);
        },
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'do not swap while detecting the source',
        build: build,
        act: (cubit) => cubit.swap(),
        expect: () => const <DictionaryState>[],
      );
    });

    group('verbosity', () {
      blocTest<DictionaryCubit, DictionaryState>(
        'is passed to the repository',
        build: () =>
            build(word: 'gato', verbosity: DictionaryVerbosity.comprehensive),
        act: (cubit) => cubit.lookUp(),
        verify: (_) =>
            verifyLookUp('gato', verbosity: DictionaryVerbosity.comprehensive),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'never starts a look-up on its own',
        build: () => build(word: 'gato'),
        act: (cubit) async {
          await cubit.setVerbosity(DictionaryVerbosity.concise);
          await cubit.setVerbosity(DictionaryVerbosity.concise);
        },
        expect: () => const [
          DictionaryState(
            word: 'gato',
            engine: claudeEngine,
            verbosity: DictionaryVerbosity.concise,
          ),
        ],
        verify: (_) => verifyNoLookUp(),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'is used by the next look-up',
        build: () => build(word: 'gato'),
        act: (cubit) async {
          await cubit.setVerbosity(DictionaryVerbosity.concise);
          await cubit.lookUp();
        },
        verify: (_) =>
            verifyLookUp('gato', verbosity: DictionaryVerbosity.concise),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'looks the shown word up again, not the edited one',
        build: () => build(word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit.setWord('perro');
          await cubit.setVerbosity(DictionaryVerbosity.comprehensive);
        },
        skip: 3,
        expect: () => const [
          DictionaryState(
            word: 'perro',
            engine: claudeEngine,
            verbosity: DictionaryVerbosity.comprehensive,
            status: DictionaryStatus.success,
            lookedUp: 'gato',
            entry: gatoEntry,
          ),
          DictionaryState(
            word: 'perro',
            engine: claudeEngine,
            verbosity: DictionaryVerbosity.comprehensive,
            status: DictionaryStatus.loading,
            lookedUp: 'gato',
          ),
          DictionaryState(
            word: 'perro',
            engine: claudeEngine,
            verbosity: DictionaryVerbosity.comprehensive,
            status: DictionaryStatus.success,
            lookedUp: 'gato',
            entry: gatoEntry,
          ),
        ],
        verify: (_) {
          verifyLookUp('gato');
          verifyLookUp('gato', verbosity: DictionaryVerbosity.comprehensive);
        },
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'replaces a loading look-up',
        setUp: () {
          final slow = Completer<DictionaryEntry>();
          var calls = 0;
          stubLookUp(repository, () {
            calls++;
            return calls == 1 ? slow.future : Future.value(gatoEntry);
          });
          addTearDown(() => slow.complete(const DictionaryEntry(word: 'old')));
        },
        build: () => build(word: 'gato'),
        act: (cubit) async {
          unawaited(cubit.lookUp());
          await cubit.setVerbosity(DictionaryVerbosity.concise);
        },
        expect: () => [
          isA<DictionaryState>().having(
            (s) => s.status,
            'status',
            DictionaryStatus.loading,
          ),
          // Still loading (an equal state is not emitted again).
          isA<DictionaryState>()
              .having(
                (s) => s.verbosity,
                'verbosity',
                DictionaryVerbosity.concise,
              )
              .having((s) => s.status, 'status', DictionaryStatus.loading),
          isA<DictionaryState>()
              .having((s) => s.status, 'status', DictionaryStatus.success)
              .having((s) => s.entry, 'entry', gatoEntry),
        ],
        verify: (_) {
          verifyLookUp('gato');
          verifyLookUp('gato', verbosity: DictionaryVerbosity.concise);
        },
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'does not retry a failed look-up',
        setUp: () => stubLookUp(repository, () async => throw StateError('x')),
        build: () => build(word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          await cubit.setVerbosity(DictionaryVerbosity.concise);
        },
        skip: 2,
        expect: () => [
          isA<DictionaryState>()
              .having(
                (s) => s.verbosity,
                'verbosity',
                DictionaryVerbosity.concise,
              )
              .having((s) => s.status, 'status', DictionaryStatus.failure),
        ],
        errors: () => [isA<StateError>()],
        verify: (_) => verifyLookUp('gato'),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'does not look up again once the engine is gone',
        build: () => build(word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          cubit.setEngine(null);
          await cubit.setVerbosity(DictionaryVerbosity.concise);
        },
        skip: 3,
        expect: () => [
          isA<DictionaryState>()
              .having(
                (s) => s.verbosity,
                'verbosity',
                DictionaryVerbosity.concise,
              )
              .having((s) => s.status, 'status', DictionaryStatus.success),
        ],
        verify: (_) => verifyLookUp('gato'),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'applies to a look-up that waits for an engine',
        build: () => build(engine: null, word: 'gato'),
        act: (cubit) async {
          await cubit.lookUp();
          await cubit.setVerbosity(DictionaryVerbosity.comprehensive);
          cubit.setEngine(claudeEngine);
          await Future<void>.delayed(Duration.zero);
        },
        verify: (_) =>
            verifyLookUp('gato', verbosity: DictionaryVerbosity.comprehensive),
      );
    });

    group('lookUpWord', () {
      blocTest<DictionaryCubit, DictionaryState>(
        'puts the word in the search field and looks it up',
        build: () => build(word: 'gatto', source: spanish),
        act: (cubit) => cubit.lookUpWord(' gato '),
        expect: () => const [
          DictionaryState(word: 'gato', source: spanish, engine: claudeEngine),
          DictionaryState(
            word: 'gato',
            source: spanish,
            engine: claudeEngine,
            status: DictionaryStatus.loading,
            lookedUp: 'gato',
          ),
          DictionaryState(
            word: 'gato',
            source: spanish,
            engine: claudeEngine,
            status: DictionaryStatus.success,
            lookedUp: 'gato',
            entry: gatoEntry,
          ),
        ],
        verify: (_) => verifyLookUp('gato', source: spanish),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'keeps the detail level',
        build: () => build(verbosity: DictionaryVerbosity.concise),
        act: (cubit) => cubit.lookUpWord('gato'),
        verify: (_) =>
            verifyLookUp('gato', verbosity: DictionaryVerbosity.concise),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'makes model output one plain line',
        build: build,
        act: (cubit) => cubit.lookUpWord('\u202Egato\n\tmontés\u2028x\u0000'),
        verify: (cubit) {
          expect(cubit.state.word, 'gato montés x');
          verifyLookUp('gato montés x');
        },
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'cuts long words',
        build: build,
        act: (cubit) => cubit.lookUpWord('${'a' * 99} ${'b' * 50}'),
        verify: (cubit) {
          expect(cubit.state.word, 'a' * 99);
          verifyLookUp('a' * 99);
        },
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'ignores blank words',
        build: () => build(word: 'gato'),
        act: (cubit) => cubit.lookUpWord(' \n\u200E '),
        expect: () => const <DictionaryState>[],
        verify: (_) => verifyNoLookUp(),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'waits for an engine like lookUp',
        build: () => build(engine: null),
        act: (cubit) async {
          await cubit.lookUpWord('gato');
          cubit.setEngine(claudeEngine);
          await Future<void>.delayed(Duration.zero);
        },
        verify: (_) => verifyLookUp('gato'),
      );
    });

    group('usage', () {
      test('counts a finished look-up of a provider engine', () async {
        final cubit = build(word: 'gato', usageTracker: tracker);
        await cubit.lookUp();
        final output =
            verify(
                  () => tracker.recordText(
                    'claude',
                    input: 'gato',
                    output: captureAny(named: 'output'),
                  ),
                ).captured.single
                as String;
        expect(output, contains('A small domesticated feline.'));
        expect(output, contains('The cat sleeps.'));
        expect(output, contains('minino'));
      });

      test('is not counted for engines without a provider', () async {
        final cubit = build(
          engine: ollamaEngine,
          word: 'gato',
          usageTracker: tracker,
        );
        await cubit.lookUp();
        verifyNever(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        );
      });

      test('ignores tracker errors', () async {
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenThrow(StateError('broken'));
        final cubit = build(word: 'gato', usageTracker: tracker);
        await cubit.lookUp();
        expect(cubit.state.status, DictionaryStatus.success);

        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => throw StateError('async'));
        await cubit.lookUp();
        expect(cubit.state.status, DictionaryStatus.success);
      });
    });
  });

  group('DictionaryState', () {
    test('isEmptyEntry is true only for an entry without content', () {
      expect(const DictionaryState().isEmptyEntry, isFalse);
      expect(
        const DictionaryState(entry: DictionaryEntry(word: 'x')).isEmptyEntry,
        isTrue,
      );
      expect(const DictionaryState(entry: gatoEntry).isEmptyEntry, isFalse);
      for (final entry in const [
        DictionaryEntry(
          word: 'x',
          examples: [DictionaryExample(source: 'x')],
        ),
        DictionaryEntry(word: 'x', synonyms: ['y']),
        DictionaryEntry(word: 'x', etymology: 'old'),
        DictionaryEntry(word: 'x', notes: 'note'),
      ]) {
        expect(DictionaryState(entry: entry).isEmptyEntry, isFalse);
      }
    });

    test('copyWith keeps or replaces values', () {
      const state = DictionaryState(
        word: 'a',
        engine: claudeEngine,
        entry: gatoEntry,
        error: 'e',
      );
      expect(state.copyWith(), state);
      expect(
        state.copyWith(verbosity: DictionaryVerbosity.concise).verbosity,
        DictionaryVerbosity.concise,
      );
      expect(
        state.copyWith(verbosity: DictionaryVerbosity.concise),
        isNot(state),
      );
      expect(
        state.copyWith(
          engine: () => null,
          entry: () => null,
          error: () => null,
        ),
        const DictionaryState(word: 'a'),
      );
    });
  });
}
