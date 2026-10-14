import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/data/translation_memory.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

final _now = DateTime(2026, 10, 14, 12);

HistoryEntry _entry(
  String id, {
  required String text,
  String? translation,
  Language source = Language.auto,
  Language target = en,
  TranslationEngine engine = deepl,
  Duration age = const Duration(hours: 1),
  String? detectedSource,
}) => HistoryEntry(
  id: id,
  text: text,
  translation: translation ?? 'translation $id',
  source: source,
  target: target,
  engineId: engine.id,
  engineName: engine.name,
  createdAt: _now.subtract(age),
  detectedSource: detectedSource,
);

const _long = 'Please send me the quarterly report by Friday';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks()..clock = () => _now;
  });

  group('memory lookup', () {
    blocTest<TranslateCubit, TranslateState>(
      'offers an exact match right away, before the engine translates',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubHistory([
            _entry('1', text: 'Hallo  Welt', translation: 'Hello world'),
          ]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('  hallo welt ');
        final match = cubit.state.memoryMatch;
        expect(match?.entry.id, '1');
        expect(match?.kind, MemoryMatchKind.exact);
        expect(cubit.state.visibleMemoryMatch, match);
        verifyNever(() => mocks.repository.translate(any(), any()));
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        // The engine still translates; its output is the result.
        expect(cubit.state.output, '  hallo welt ->en');
        expect(cubit.state.resultFromMemory, isFalse);
        // The earlier translation differs: still offered.
        expect(cubit.state.visibleMemoryMatch?.entry.id, '1');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'finds nothing for other text',
      setUp: () => mocks.stubHistory([_entry('1', text: 'Hallo Welt')]),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.setInput('Guten Morgen'),
      verify: (cubit) => expect(cubit.state.memoryMatch, isNull),
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs the same target language',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubHistory([_entry('1', text: 'Hallo Welt', target: fr)]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit.setInput('Hallo Welt');
        expect(cubit.state.memoryMatch, isNull);
        cubit.setTarget(fr);
        expect(cubit.state.memoryMatch?.entry.id, '1');
        cubit.setTarget(de);
        expect(cubit.state.memoryMatch, isNull);
        await Future<void>.delayed(afterDebounce);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs a compatible source language',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubHistory([_entry('1', text: 'Hallo Welt', source: de)]);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo Welt', source: fr),
      act: (cubit) async {
        cubit
          ..setInput('Hallo Welt!')
          ..setInput('Hallo Welt');
        expect(cubit.state.memoryMatch, isNull);
        cubit.setSource(de);
        expect(cubit.state.memoryMatch?.entry.id, '1');
        cubit.setSource(Language.auto);
        expect(cubit.state.memoryMatch?.entry.id, '1');
        await Future<void>.delayed(afterDebounce);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'offers similar text of at least 20 characters',
      setUp: () => mocks.stubHistory([
        _entry('1', text: 'Please send me the quarterly report by Monday'),
      ]),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.setInput(_long),
      verify: (cubit) {
        final match = cubit.state.memoryMatch;
        expect(match?.kind, MemoryMatchKind.similar);
        expect(match!.similarity, greaterThanOrEqualTo(0.85));
        expect(
          match.diff.last,
          const MemoryDiffSegment(' Friday', MemoryDiffOp.added),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'finds nothing with history off',
      setUp: () {
        mocks
          ..stubSettings(const AppSettings(saveHistory: false))
          ..stubHistory([_entry('1', text: 'Hallo Welt')]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.setInput('Hallo Welt'),
      verify: (cubit) => expect(cubit.state.memoryMatch, isNull),
    );

    blocTest<TranslateCubit, TranslateState>(
      'skips entries older than the history retention',
      setUp: () {
        mocks
          ..stubSettings(
            const AppSettings(historyRetention: HistoryRetention.day),
          )
          ..stubHistory([
            _entry('1', text: 'Hallo Welt', age: const Duration(days: 2)),
          ]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.setInput('Hallo Welt'),
      verify: (cubit) => expect(cubit.state.memoryMatch, isNull),
    );

    blocTest<TranslateCubit, TranslateState>(
      'is cleared with the input',
      setUp: () => mocks.stubHistory([_entry('1', text: 'Hallo Welt')]),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) {
        cubit.setInput('Hallo Welt');
        expect(cubit.state.memoryMatch, isNotNull);
        cubit.setInput(' ');
        expect(cubit.state.memoryMatch, isNull);
        cubit.setInput('Hallo Welt');
        expect(cubit.state.memoryMatch, isNotNull);
        cubit.clear();
      },
      verify: (cubit) => expect(cubit.state.memoryMatch, isNull),
    );

    group('turning history off', () {
      late StreamController<AppSettings> settings;

      setUp(() {
        settings = StreamController<AppSettings>();
        addTearDown(settings.close);
        when(() => mocks.settings.stream).thenAnswer((_) => settings.stream);
      });

      blocTest<TranslateCubit, TranslateState>(
        'hides the match',
        setUp: () => mocks.stubHistory([_entry('1', text: 'Hallo Welt')]),
        build: () => mocks.build(),
        seed: readyState,
        act: (cubit) async {
          cubit.setInput('Hallo Welt');
          expect(cubit.state.memoryMatch, isNotNull);
          // Another setting: the match stays.
          settings.add(const AppSettings(instantTranslate: false));
          await Future<void>.delayed(Duration.zero);
          expect(cubit.state.memoryMatch, isNotNull);
          const off = AppSettings(saveHistory: false);
          mocks.stubSettings(off);
          settings.add(off);
          await Future<void>.delayed(Duration.zero);
        },
        verify: (cubit) => expect(cubit.state.memoryMatch, isNull),
      );
    });

    group('while typing', () {
      blocTest<TranslateCubit, TranslateState>(
        'translations of the text being typed are not offered as similar',
        setUp: () => mocks.stubTranslate(),
        build: () => mocks.build(),
        seed: readyState,
        act: (cubit) async {
          cubit.setInput(_long);
          await Future<void>.delayed(afterDebounce);
          final recorded = mocks.historyEntries().single;
          mocks.stubHistory([recorded]);
          cubit.setInput('$_long.');
          expect(cubit.state.memoryMatch, isNull);
          // Back to the recorded text: an exact match is fine.
          cubit.setInput(_long);
          expect(cubit.state.memoryMatch?.entry, recorded);
          // A new text (after clearing) may match it as similar text.
          cubit
            ..clear()
            ..setInput('$_long.');
          expect(cubit.state.memoryMatch?.kind, MemoryMatchKind.similar);
          // Text from elsewhere starts afresh too.
          await Future<void>.delayed(afterDebounce);
          final typed = mocks.historyEntries().last;
          expect(typed.text, '$_long.');
          mocks.stubHistory([typed]);
          cubit.setInput('$_long.!');
          expect(cubit.state.memoryMatch, isNull);
          cubit.setInputAndTranslate('$_long!');
          expect(cubit.state.memoryMatch?.kind, MemoryMatchKind.similar);
          expect(cubit.state.memoryMatch?.entry, typed);
          await Future<void>.delayed(afterDebounce);
        },
      );

      blocTest<TranslateCubit, TranslateState>(
        'external text starts afresh',
        setUp: () => mocks.stubTranslate(),
        build: () => mocks.build(),
        seed: readyState,
        act: (cubit) async {
          cubit.setInput(_long);
          await Future<void>.delayed(afterDebounce);
          final recorded = mocks.historyEntries().single;
          mocks.stubHistory([recorded]);
          cubit.setExternalInput('$_long?');
          expect(cubit.state.memoryMatch?.entry, recorded);
          await Future<void>.delayed(afterDebounce);
        },
      );
    });
  });

  group('useMemoryMatch', () {
    late _MockUsageTracker tracker;

    setUp(() {
      tracker = _MockUsageTracker();
      mocks.usageTracker = tracker;
    });

    blocTest<TranslateCubit, TranslateState>(
      'shows the earlier translation instead of asking the engine',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubHistory([
            _entry(
              '1',
              text: 'Hallo Welt',
              translation: 'Hello world',
              detectedSource: 'de',
            ),
          ]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit
          ..setInput('hallo welt')
          ..useMemoryMatch();
        await Future<void>.delayed(afterDebounce);
      },
      verify: (cubit) {
        final state = cubit.state;
        expect(state.output, 'Hello world');
        expect(state.result?.engineName, deepl.name);
        expect(state.result?.fromCache, isTrue);
        expect(state.result?.detectedSource, 'de');
        expect(state.resultFromMemory, isTrue);
        expect(state.instantResult, isTrue);
        expect(state.isResultStale, isFalse);
        expect(state.status, TranslateStatus.success);
        // Shown already: the card hides.
        expect(state.memoryMatch, isNotNull);
        expect(state.visibleMemoryMatch, isNull);
        // The pending instant translation was cancelled: nothing billed or
        // recorded again.
        verifyNever(() => mocks.repository.translate(any(), any()));
        verifyNever(() => mocks.history.add(any()));
        verifyNever(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'cancels a running translation',
      setUp: () {
        mocks.stubHistory([
          _entry('1', text: 'Hallo Welt', translation: 'Hello world'),
        ]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        final controller = StreamController<TranslationResult>();
        addTearDown(controller.close);
        when(() => mocks.repository.translate(any(), any()))
            .thenAnswer((_) => controller.stream);
        cubit.setInput('Hallo Welt');
        unawaited(cubit.translate());
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.status, TranslateStatus.translating);
        cubit.useMemoryMatch();
        expect(controller.hasListener, isFalse);
        controller.add(resultOf('late'));
        await Future<void>.delayed(Duration.zero);
      },
      verify: (cubit) {
        expect(cubit.state.output, 'Hello world');
        expect(cubit.state.status, TranslateStatus.success);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a similar match reads as the translation of its own text',
      setUp: () => mocks.stubHistory([
        _entry(
          '1',
          text: 'Please send me the quarterly report by Monday',
          translation: 'Bitte … Montag',
        ),
      ]),
      build: () => mocks.build(),
      seed: () => readyState(input: 'x'),
      act: (cubit) => cubit
        ..setInput(_long)
        ..useMemoryMatch(),
      verify: (cubit) {
        expect(cubit.state.output, 'Bitte … Montag');
        expect(cubit.state.resultFromMemory, isTrue);
        expect(cubit.state.isResultStale, isTrue);
        expect(cubit.state.visibleMemoryMatch, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a fresh translation replaces it',
      setUp: () {
        mocks
          ..stubTranslate()
          ..stubHistory([
            _entry('1', text: 'Hallo Welt', translation: 'Hello world'),
          ]);
      },
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) async {
        cubit
          ..setInput('Hallo Welt')
          ..useMemoryMatch();
        await cubit.translate();
      },
      verify: (cubit) {
        expect(cubit.state.output, 'Hallo Welt->en');
        expect(cubit.state.resultFromMemory, isFalse);
        expect(cubit.state.visibleMemoryMatch?.entry.id, '1');
        expect(mocks.historyEntries().single.translation, 'Hallo Welt->en');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing without a match',
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.useMemoryMatch(),
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing in compare mode',
      setUp: () => mocks.stubHistory([_entry('1', text: 'Hallo')]),
      build: () => mocks.build(),
      seed: () => readyState().copyWith(compareMode: true),
      act: (cubit) {
        cubit.setInput('Hallo');
        expect(cubit.state.memoryMatch, isNotNull);
        expect(cubit.state.visibleMemoryMatch, isNull);
        cubit.useMemoryMatch();
      },
      verify: (cubit) => expect(cubit.state.result, isNull),
    );
  });

  group('dismissMemoryMatch', () {
    blocTest<TranslateCubit, TranslateState>(
      'hides the match until the input changes',
      setUp: () => mocks.stubHistory([_entry('1', text: 'Hallo')]),
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) {
        cubit
          ..setInput('Hallo')
          ..dismissMemoryMatch();
        expect(cubit.state.memoryMatch, isNull);
        cubit.setInput('hallo ');
      },
      verify: (cubit) => expect(cubit.state.memoryMatch?.entry.id, '1'),
    );

    blocTest<TranslateCubit, TranslateState>(
      'does nothing without a match',
      build: () => mocks.build(),
      seed: readyState,
      act: (cubit) => cubit.dismissMemoryMatch(),
      expect: () => <TranslateState>[],
    );
  });

  group('TranslateState', () {
    final match = MemoryMatch(
      entry: _entry('1', text: 'Hallo', translation: 'Hello'),
      kind: MemoryMatchKind.exact,
      similarity: 1,
    );

    test('a new result is not from memory', () {
      final state = readyState(
        input: 'Hallo',
        result: resultOf('Hello'),
      ).copyWith(resultFromMemory: true, memoryMatch: () => match);
      expect(state.resultFromMemory, isTrue);
      expect(
        state.copyWith(status: TranslateStatus.idle).resultFromMemory,
        isTrue,
      );
      expect(
        state.copyWith(result: () => resultOf('Hi')).resultFromMemory,
        isFalse,
      );
    });

    test('visibleMemoryMatch hides a match the output already shows', () {
      final base = readyState(input: 'Hallo')
          .copyWith(memoryMatch: () => match);
      expect(base.visibleMemoryMatch, match);
      expect(
        base.copyWith(result: () => resultOf(' hello ')).visibleMemoryMatch,
        isNull,
      );
      expect(
        base.copyWith(result: () => resultOf('Hi')).visibleMemoryMatch,
        match,
      );
      // The output belongs to other text: still offered.
      expect(
        base
            .copyWith(
              result: () => resultOf('Hello'),
              resultInput: () => 'Hall',
            )
            .visibleMemoryMatch,
        match,
      );
      expect(base.copyWith(compareMode: true).visibleMemoryMatch, isNull);
    });
  });
}
