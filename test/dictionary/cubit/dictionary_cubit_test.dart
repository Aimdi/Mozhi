import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/history/history.dart'
    show HistoryEntry, HistoryEntryKind, HistoryState, HistoryStatus;
import 'package:mozhi/settings/models/app_settings.dart';
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
          entryLanguage: 'es',
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

    group('entry language', () {
      DictionaryCubit identifying(
        Future<String?> Function(String text) identify, {
        Language source = Language.auto,
      }) => DictionaryCubit(
        repository: repository,
        engine: claudeEngine,
        word: 'gato',
        source: source,
        identifyLanguage: identify,
      );

      test('is the chosen source language', () async {
        final cubit = identifying((_) async => 'it', source: spanish);
        await cubit.lookUp();
        expect(cubit.state.entryLanguage, 'es');
        await cubit.close();
      });

      test("is identified on the device from the entry's own words", () async {
        String? asked;
        final cubit = identifying((text) async {
          asked = text;
          return 'es';
        });
        await cubit.lookUp();
        await pumpEventQueue();
        expect(cubit.state.entryLanguage, 'es');
        // The headword, the examples and the synonyms, one per line.
        expect(asked, contains('gato'));
        for (final example in gatoEntry.examples) {
          expect(asked, contains(example.source));
        }
        await cubit.close();
      });

      test('stays unknown for an unknown code, a failure or none', () async {
        for (final identify in <Future<String?> Function(String)>[
          (_) async => 'zz-not-a-language',
          (_) async => throw StateError('no'),
          (_) async => null,
          (_) async => '  ',
        ]) {
          final cubit = identifying(identify);
          await cubit.lookUp();
          await pumpEventQueue();
          expect(cubit.state.entryLanguage, isNull);
          await cubit.close();
        }
        // Without an identifier.
        final cubit = build(word: 'gato');
        await cubit.lookUp();
        await pumpEventQueue();
        expect(cubit.state.entryLanguage, isNull);
        await cubit.close();
      });

      test('takes a script only one language uses', () async {
        stubLookUp(repository, () async => const DictionaryEntry(word: 'ねこ'));
        var asked = false;
        final cubit = identifying((_) async {
          asked = true;
          return 'zh';
        });
        await cubit.lookUp();
        await pumpEventQueue();
        expect(cubit.state.entryLanguage, 'ja');
        expect(asked, isFalse);
        await cubit.close();
      });

      test('ignores the answer for an older look-up', () async {
        final answer = Completer<String?>();
        final cubit = identifying((_) => answer.future);
        await cubit.lookUp();
        cubit.closeEntry();
        answer.complete('es');
        await pumpEventQueue();
        expect(cubit.state.entryLanguage, isNull);
        await cubit.close();
      });

      test('is cleared by a new look-up and by clear', () async {
        final cubit = identifying((_) async => 'es', source: spanish);
        await cubit.lookUp();
        expect(cubit.state.entryLanguage, 'es');
        cubit.clear();
        expect(cubit.state.entryLanguage, isNull);
        await cubit.close();
      });

      test('dictionaryScriptLanguage knows scripts of one language', () {
        expect(dictionaryScriptLanguage('고양이'), 'ko');
        expect(dictionaryScriptLanguage('カタカナ'), 'ja');
        expect(dictionaryScriptLanguage('แมว'), 'th');
        expect(dictionaryScriptLanguage('γάτα'), 'el');
        expect(dictionaryScriptLanguage('კატა'), 'ka');
        expect(dictionaryScriptLanguage('կատու'), 'hy');
        expect(dictionaryScriptLanguage('பூனை'), 'ta');
        expect(dictionaryScriptLanguage('cat'), isNull);
        expect(dictionaryScriptLanguage('кот'), isNull);
        expect(dictionaryScriptLanguage('猫'), isNull);
      });
    });

    group('engine choice', () {
      test(
        'pickEngine uses the picked engine and looks the word up again',
        () async {
          final cubit = build(word: 'gato', source: spanish);
          await cubit.lookUp();
          cubit.pickEngine(ollamaEngine);
          expect(cubit.state.engine, ollamaEngine);
          await pumpEventQueue();
          verify(
            () => repository.lookUp(
              ollamaEngine,
              'gato',
              source: spanish,
              target: english,
              uiLanguage: 'German',
            ),
          ).called(1);
          await cubit.close();
        },
      );

      test('pickEngine ignores engines without AI extras', () {
        final cubit = build()..pickEngine(googleEngine);
        expect(cubit.state.engine, claudeEngine);
      });

      test('pickEngine of the engine in use looks nothing up', () async {
        final cubit = build(word: 'gato')..pickEngine(claudeEngine);
        expect(cubit.state.engine, claudeEngine);
        verifyNoLookUp();
        await cubit.close();
      });

      test('updateEngines keeps the picked engine while it is there', () {
        final cubit = build()
          ..pickEngine(ollamaEngine)
          ..updateEngines(const [
            claudeEngine,
            ollamaEngine,
          ], preferred: claudeEngine);
        expect(cubit.state.engine, ollamaEngine);
        // Gone: back to the app's engine.
        cubit.updateEngines(const [claudeEngine], preferred: claudeEngine);
        expect(cubit.state.engine, claudeEngine);
        // And it is no longer kept.
        cubit.updateEngines(const [
          claudeEngine,
          ollamaEngine,
        ], preferred: claudeEngine);
        expect(cubit.state.engine, claudeEngine);
      });

      test('updateEngines follows the app without a pick', () {
        final cubit = build()
          ..updateEngines(const [ollamaEngine], preferred: ollamaEngine);
        expect(cubit.state.engine, ollamaEngine);
        cubit.updateEngines(const []);
        expect(cubit.state.engine, isNull);
      });
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
            entryLanguage: 'es',
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

  group('DictionaryCubit history', () {
    late MockHistoryCubit history;
    late MockSettingsCubit settings;
    final now = DateTime(2026, 10, 20, 9, 30);

    setUp(() {
      history = createDictionaryHistory();
      settings = MockSettingsCubit();
      when(() => settings.state).thenReturn(const AppSettings());
    });

    DictionaryCubit build({
      String word = 'gato',
      Language source = spanish,
      DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
      bool withSettings = true,
    }) => DictionaryCubit(
      repository: repository,
      engine: claudeEngine,
      word: word,
      source: source,
      verbosity: verbosity,
      uiLanguage: 'German',
      history: history,
      settings: withSettings ? settings : null,
      clock: () => now,
    );

    /// The entry given to [MockHistoryCubit.add] (once).
    HistoryEntry added() =>
        verify(() => history.add(captureAny())).captured.single as HistoryEntry;

    void verifyNothingSaved() {
      verifyNever(() => history.add(any()));
      verifyNever(() => history.toggleFavorite(any()));
    }

    group('saves look-ups', () {
      test('that found an entry, with the word, languages, engine, '
          'detail level and a summary', () async {
        await build(verbosity: DictionaryVerbosity.concise).lookUp();

        expect(
          added(),
          HistoryEntry(
            id: 'dictionary:${now.microsecondsSinceEpoch}',
            kind: HistoryEntryKind.dictionary,
            text: 'gato',
            translation: 'noun · A small domesticated feline.',
            source: spanish,
            target: english,
            engineId: 'ai:claude',
            engineName: 'Claude',
            createdAt: now,
            verbosity: DictionaryVerbosity.concise,
          ),
        );
      });

      test('of the word looked up, with the languages it was looked up '
          'in', () async {
        final cubit = build(source: Language.auto);
        await cubit.lookUpWord('  minino ');

        final entry = added();
        expect(entry.text, 'minino');
        expect(entry.source, Language.auto);
        expect(entry.isFavorite, isFalse);
      });

      test('not while history is off', () async {
        when(() => settings.state)
            .thenReturn(const AppSettings(saveHistory: false));
        await build().lookUp();
        verifyNothingSaved();
      });

      test('not in incognito', () async {
        when(() => settings.state)
            .thenReturn(const AppSettings(incognito: true));
        await build().lookUp();
        verifyNothingSaved();
      });

      test('not without the settings', () async {
        await build(withSettings: false).lookUp();
        verifyNothingSaved();
      });

      test('not for an empty entry or a failure', () async {
        stubLookUp(repository, () async => const DictionaryEntry(word: 'xq'));
        final cubit = build(word: 'xq');
        await cubit.lookUp();
        expect(cubit.state.isEmptyEntry, isTrue);

        stubLookUp(repository, () async => throw StateError('offline'));
        await cubit.lookUp();
        expect(cubit.state.status, DictionaryStatus.failure);
        verifyNothingSaved();
      });

      test('without failing the look-up when history fails', () async {
        when(() => history.add(any())).thenThrow(StateError('sync'));
        final cubit = build();
        await cubit.lookUp();
        expect(cubit.state.status, DictionaryStatus.success);

        when(() => history.add(any()))
            .thenAnswer((_) async => throw StateError('async'));
        await cubit.lookUp();
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.status, DictionaryStatus.success);
      });
    });

    group('toggleFavorite', () {
      test('toggles the favourite of the saved look-up', () async {
        when(() => history.state).thenReturn(
          HistoryState(status: HistoryStatus.ready, entries: [gatoLookUp()]),
        );
        final cubit = build();
        await cubit.lookUp();

        await cubit.toggleFavorite();

        verify(() => history.toggleFavorite('dictionary:1')).called(1);
        // Only the recording of the look-up was added.
        verify(() => history.add(any())).called(1);
      });

      test('saves the look-up as a favourite when the history does not '
          'have it, even with history off', () async {
        when(() => settings.state)
            .thenReturn(const AppSettings(saveHistory: false));
        final cubit = build(verbosity: DictionaryVerbosity.comprehensive);
        await cubit.lookUp();

        await cubit.toggleFavorite();

        final entry = added();
        expect(entry.isFavorite, isTrue);
        expect(entry.isDictionary, isTrue);
        expect(entry.text, 'gato');
        expect(entry.verbosity, DictionaryVerbosity.comprehensive);
        verifyNever(() => history.toggleFavorite(any()));
      });

      test('a quick second tap takes the new favourite out again', () async {
        when(() => settings.state)
            .thenReturn(const AppSettings(saveHistory: false));
        var entries = <HistoryEntry>[];
        when(() => history.state).thenAnswer(
          (_) => HistoryState(status: HistoryStatus.ready, entries: entries),
        );
        final saving = Completer<void>();
        when(() => history.add(any())).thenAnswer((invocation) async {
          await saving.future;
          entries = [invocation.positionalArguments.single as HistoryEntry];
        });
        final cubit = build();
        await cubit.lookUp();

        // Both taps before the favourite is in the history.
        final first = cubit.toggleFavorite();
        final second = cubit.toggleFavorite();
        await Future<void>.delayed(Duration.zero);
        verifyNever(() => history.toggleFavorite(any()));
        saving.complete();
        await Future.wait([first, second]);

        verify(() => history.add(any())).called(1);
        verify(() => history.toggleFavorite(entries.single.id)).called(1);
      });

      test('does nothing without a shown entry', () async {
        final cubit = build();
        await cubit.toggleFavorite();

        stubLookUp(repository, () async => const DictionaryEntry(word: 'xq'));
        await cubit.lookUp();
        await cubit.toggleFavorite();

        stubLookUp(repository, () async => throw StateError('offline'));
        await cubit.lookUp();
        await cubit.toggleFavorite();
        verifyNothingSaved();
      });

      test('does nothing without a history', () async {
        final cubit = DictionaryCubit(
          repository: repository,
          engine: claudeEngine,
          word: 'gato',
        );
        await cubit.lookUp();
        await cubit.toggleFavorite();
        expect(cubit.state.status, DictionaryStatus.success);
      });

      blocTest<DictionaryCubit, DictionaryState>(
        'reports history errors',
        build: () {
          when(() => history.add(any()))
              .thenAnswer((_) async => throw StateError('full'));
          when(() => settings.state)
              .thenReturn(const AppSettings(saveHistory: false));
          return build();
        },
        act: (cubit) async {
          await cubit.lookUp();
          await cubit.toggleFavorite();
        },
        skip: 2,
        expect: () => <DictionaryState>[],
        errors: () => [isA<StateError>()],
      );
    });

    group('open', () {
      blocTest<DictionaryCubit, DictionaryState>(
        'looks a word up once with new languages and detail level',
        build: () => build(word: ''),
        act: (cubit) => cubit.open(
          ' perro ',
          source: french,
          target: spanish,
          verbosity: DictionaryVerbosity.comprehensive,
        ),
        expect: () => [
          isA<DictionaryState>()
              .having((s) => s.word, 'word', 'perro')
              .having((s) => s.source, 'source', french)
              .having((s) => s.target, 'target', spanish)
              .having(
                (s) => s.verbosity,
                'verbosity',
                DictionaryVerbosity.comprehensive,
              )
              .having((s) => s.status, 'status', DictionaryStatus.idle),
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
        verify: (_) => verify(
          () => repository.lookUp(
            claudeEngine,
            'perro',
            source: french,
            target: spanish,
            uiLanguage: 'German',
            verbosity: DictionaryVerbosity.comprehensive,
          ),
        ).called(1),
      );

      blocTest<DictionaryCubit, DictionaryState>(
        'keeps the languages and level it cannot use or is not given',
        build: build,
        act: (cubit) => cubit.open(
          'perro',
          source: const Language.custom('Pirate'),
          target: Language.auto,
        ),
        verify: (cubit) {
          expect(cubit.state.source, spanish);
          expect(cubit.state.target, english);
          expect(cubit.state.verbosity, DictionaryVerbosity.standard);
          expect(cubit.state.lookedUp, 'perro');
        },
      );
    });

    group('historySummary', () {
      test('is the part of speech and the first definition', () {
        expect(
          DictionaryCubit.historySummary(gatoEntry),
          'noun · A small domesticated feline.',
        );
      });

      test("takes the entry's part of speech when the sense has none", () {
        const entry = DictionaryEntry(
          word: 'hola',
          partsOfSpeech: ['interjection'],
          senses: [
            DictionarySense(definition: '  '),
            DictionarySense(definition: 'A\ngreeting.\u202E'),
          ],
        );
        expect(
          DictionaryCubit.historySummary(entry),
          'interjection · A greeting.',
        );
      });

      test('is the definition alone without a part of speech', () {
        const entry = DictionaryEntry(
          word: 'hola',
          senses: [DictionarySense(definition: 'A greeting.')],
        );
        expect(DictionaryCubit.historySummary(entry), 'A greeting.');
      });

      test('is the first translation without definitions', () {
        const entry = DictionaryEntry(
          word: 'hola',
          senses: [
            DictionarySense(definition: '', translations: [' ']),
            DictionarySense(definition: '', translations: ['hello', 'hi']),
          ],
        );
        expect(DictionaryCubit.historySummary(entry), 'hello');
      });

      test('is empty without definitions or translations', () {
        expect(
          DictionaryCubit.historySummary(const DictionaryEntry(word: 'x')),
          isEmpty,
        );
      });

      test('is cut to maxSummaryLength', () {
        final entry = DictionaryEntry(
          word: 'x',
          senses: [DictionarySense(definition: 'word ' * 100)],
        );
        final summary = DictionaryCubit.historySummary(entry);
        expect(summary.length, lessThanOrEqualTo(300));
        expect(summary, endsWith('word…'));
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
