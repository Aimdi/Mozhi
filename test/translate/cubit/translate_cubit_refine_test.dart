import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  final formal = RefinementSuggestion.defaults[0];
  final casual = RefinementSuggestion.defaults[1];
  final shorter = RefinementSuggestion.defaults[2];
  final simpler = RefinementSuggestion.defaults[3];
  final tags = {
    formal.instruction: 'formal',
    casual.instruction: 'casual',
    shorter.instruction: 'short',
    simpler.instruction: 'simple',
  };

  final hallo = resultOf('Hallo Welt', engine: claude, detected: 'en');

  /// "Hello world" (auto, detected English) translated to German by Claude.
  TranslateState translated() => readyState(
    engine: claude,
    input: 'Hello world',
    target: de,
    result: hallo,
    status: TranslateStatus.success,
  );

  TranslationResult refined(String text) =>
      resultOf(text, engine: claude, detected: 'en');

  void stubRefine() => mocks.stubRefine(tags);

  /// Refine calls that never finish; returns their controller.
  StreamController<TranslationResult> stubPendingRefine() {
    final controller = StreamController<TranslationResult>.broadcast();
    addTearDown(controller.close);
    when(
      () => mocks.repository.refine(
        any(),
        any(),
        currentTranslation: any(named: 'currentTranslation'),
        instruction: any(named: 'instruction'),
      ),
    ).thenAnswer((_) => controller.stream);
    return controller;
  }

  group('applySuggestion on AI engines with the general profile', () {
    blocTest<TranslateCubit, TranslateState>(
      'refines the current translation instead of translating again',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(formal),
      expect: () => [
        translated().copyWith(pendingRefinement: () => formal),
        translated().copyWith(
          result: () => refined('Hallo Welt+formal'),
          appliedRefinements: [
            AppliedRefinement(suggestion: formal, previous: hallo),
          ],
        ),
      ],
      verify: (cubit) {
        final (request, current, instruction) = mocks.refineCalls().single;
        expect(request.text, 'Hello world');
        // The detected language is passed on.
        expect(request.source, en);
        expect(request.target, de);
        expect(current, 'Hallo Welt');
        expect(instruction, formal.instruction);
        verifyNever(() => mocks.repository.translate(any(), any()));
        expect(mocks.historyEntries().single.translation, 'Hallo Welt+formal');
        expect(cubit.state.isSuggestionApplied(formal), isTrue);
        expect(cubit.state.appliedSuggestions, [formal]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'passes fetched suggestions as a lower-trust refinement',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(
        const RefinementSuggestion(label: 'Warmer', instruction: 'Be warm.'),
      ),
      verify: (_) {
        expect(
          mocks.refineCalls().single.$3,
          '${TranslateCubit.refinementPrefix} Be warm.',
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'stacks refinements, each with the translation before it',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.applySuggestion(formal);
        await cubit.applySuggestion(simpler);
      },
      verify: (cubit) {
        expect(cubit.state.output, 'Hallo Welt+formal+simple');
        expect(cubit.state.appliedRefinements, [
          AppliedRefinement(suggestion: formal, previous: hallo),
          AppliedRefinement(
            suggestion: simpler,
            previous: refined('Hallo Welt+formal'),
          ),
        ]);
        expect(mocks.refineCalls().map((c) => c.$2), [
          'Hallo Welt',
          'Hallo Welt+formal',
        ]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a chip of an applied exclusive group replaces that chip and drops '
      'the chips applied after it',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.applySuggestion(formal);
        await cubit.applySuggestion(simpler);
        await cubit.applySuggestion(casual);
      },
      verify: (cubit) {
        expect(cubit.state.output, 'Hallo Welt+casual');
        expect(cubit.state.appliedRefinements, [
          AppliedRefinement(suggestion: casual, previous: hallo),
        ]);
        // Refined from the translation before "More formal".
        expect(mocks.refineCalls().last.$2, 'Hallo Welt');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'replacing a later chip of a group keeps the chips before it',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.applySuggestion(simpler);
        await cubit.applySuggestion(formal);
        await cubit.applySuggestion(casual);
      },
      verify: (cubit) {
        expect(cubit.state.output, 'Hallo Welt+simple+casual');
        expect(cubit.state.appliedSuggestions, [simpler, casual]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'toggling the last chip off restores the translation before it',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.applySuggestion(formal);
        await cubit.applySuggestion(simpler);
        await cubit.applySuggestion(simpler);
      },
      verify: (cubit) {
        expect(cubit.state.result, refined('Hallo Welt+formal'));
        expect(cubit.state.appliedSuggestions, [formal]);
        expect(cubit.state.status, TranslateStatus.success);
        // No request for toggling off; history follows the output.
        expect(mocks.refineCalls(), hasLength(2));
        expect(mocks.historyEntries().last.translation, 'Hallo Welt+formal');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'toggling an earlier chip off drops the chips after it',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.applySuggestion(formal);
        await cubit.applySuggestion(simpler);
        await cubit.applySuggestion(formal);
      },
      verify: (cubit) {
        expect(cubit.state.result, hallo);
        expect(cubit.state.appliedRefinements, isEmpty);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'shows the translation until the refinement is complete',
      setUp: () {
        final controller = stubPendingRefine();
        unawaited(
          Future<void>(() {
            controller.add(resultOf('Sehr', engine: claude, isComplete: false));
          }),
        );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        unawaited(cubit.applySuggestion(formal));
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [translated().copyWith(pendingRefinement: () => formal)],
      verify: (cubit) => expect(cubit.state.isRefining, isTrue),
    );

    test('applying the chip in flight again cancels it', () async {
      final controller = stubPendingRefine();
      final cubit = mocks.build()..emit(translated());
      addTearDown(cubit.close);
      final done = cubit.applySuggestion(formal);
      expect(cubit.state.pendingRefinement, formal);
      expect(controller.hasListener, isTrue);

      await cubit.applySuggestion(formal);
      await done;
      expect(cubit.state, translated());
      expect(controller.hasListener, isFalse);
    });

    test('another chip cancels the one in flight', () async {
      final first = StreamController<TranslationResult>();
      addTearDown(first.close);
      var calls = 0;
      when(
        () => mocks.repository.refine(
          any(),
          any(),
          currentTranslation: any(named: 'currentTranslation'),
          instruction: any(named: 'instruction'),
        ),
      ).thenAnswer((invocation) {
        if (calls++ == 0) return first.stream;
        final current =
            invocation.namedArguments[#currentTranslation] as String;
        return Stream.value(refined('$current+second'));
      });
      final cubit = mocks.build()..emit(translated());
      addTearDown(cubit.close);
      unawaited(cubit.applySuggestion(formal));
      await cubit.applySuggestion(simpler);

      expect(first.hasListener, isFalse);
      expect(cubit.state.output, 'Hallo Welt+second');
      expect(cubit.state.appliedSuggestions, [simpler]);
      // A late result of the cancelled one changes nothing.
      first.add(refined('late'));
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.output, 'Hallo Welt+second');
    });

    final failure = Exception('rate limited');

    blocTest<TranslateCubit, TranslateState>(
      'keeps the translation and reports a failure',
      setUp: () {
        when(
          () => mocks.repository.refine(
            any(),
            any(),
            currentTranslation: any(named: 'currentTranslation'),
            instruction: any(named: 'instruction'),
          ),
        ).thenAnswer((_) => Stream.error(failure));
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(formal),
      expect: () => [
        translated().copyWith(pendingRefinement: () => formal),
        translated().copyWith(refinementError: () => failure),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'reports a refine call that throws',
      setUp: () {
        when(
          () => mocks.repository.refine(
            any(),
            any(),
            currentTranslation: any(named: 'currentTranslation'),
            instruction: any(named: 'instruction'),
          ),
        ).thenThrow(failure);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(formal),
      expect: () => [
        translated().copyWith(pendingRefinement: () => formal),
        translated().copyWith(refinementError: () => failure),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'the next refinement clears the error',
      setUp: () {
        var calls = 0;
        when(
          () => mocks.repository.refine(
            any(),
            any(),
            currentTranslation: any(named: 'currentTranslation'),
            instruction: any(named: 'instruction'),
          ),
        ).thenAnswer(
          (_) => calls++ == 0
              ? Stream.error(failure)
              : Stream.value(refined('Hallo!')),
        );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.applySuggestion(formal);
        await cubit.applySuggestion(formal);
      },
      verify: (cubit) {
        expect(cubit.state.refinementError, isNull);
        expect(cubit.state.output, 'Hallo!');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'ends without a change when the refinement yields nothing',
      setUp: () {
        when(
          () => mocks.repository.refine(
            any(),
            any(),
            currentTranslation: any(named: 'currentTranslation'),
            instruction: any(named: 'instruction'),
          ),
        ).thenAnswer((_) => const Stream.empty());
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(formal),
      expect: () => [
        translated().copyWith(pendingRefinement: () => formal),
        translated(),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'translates again with the instruction when the model cannot refine',
      setUp: () {
        mocks.stubTranslate(resultOf('Guten Tag', engine: claude));
        when(
          () => mocks.repository.refine(
            any(),
            any(),
            currentTranslation: any(named: 'currentTranslation'),
            instruction: any(named: 'instruction'),
          ),
        ).thenAnswer((_) => Stream.error(UnsupportedError('no')));
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(formal),
      verify: (cubit) {
        final request = mocks.translateRequests().single;
        expect(request.options.instructions, formal.instruction);
        expect(cubit.state.output, 'Guten Tag');
        expect(cubit.state.appliedRefinements, isEmpty);
        expect(cubit.state.pendingRefinement, isNull);
        expect(cubit.state.refinementError, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'resets what belongs to the old output but keeps the chips',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        alternativesStatus: ExtraStatus.ready,
        alternatives: () =>
            const AlternativeTranslations(description: 'd', alternatives: []),
        insightsStatus: ExtraStatus.ready,
        insights: const [WordInsight(sourceText: 's', targetText: 'Welt')],
        explainStatus: ExtraStatus.ready,
        explanation: 'md',
        suggestionsStatus: ExtraStatus.ready,
        suggestions: [...RefinementSuggestion.defaults, _warmer],
        romanizationStatus: ExtraStatus.ready,
        romanization: () => 'Hallo Welt',
        dictionaryStatus: ExtraStatus.ready,
        dictionary: () => const DictionaryEntry(word: 'hello'),
      ),
      act: (cubit) => cubit.applySuggestion(formal),
      verify: (cubit) {
        final state = cubit.state;
        expect(state.alternatives, isNull);
        expect(state.alternativesStatus, ExtraStatus.idle);
        expect(state.insights, isEmpty);
        expect(state.explanation, isEmpty);
        expect(state.romanization, isNull);
        expect(state.suggestions, [...RefinementSuggestion.defaults, _warmer]);
        expect(state.suggestionsStatus, ExtraStatus.ready);
        expect(state.dictionary, isNotNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'counts refinements as provider usage',
      setUp: () {
        stubRefine();
        final tracker = _MockUsageTracker();
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => const UsageStats(requests: 1));
        mocks.usageTracker = tracker;
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(formal),
      verify: (_) {
        verify(
          () => mocks.usageTracker!.recordText(
            'claude',
            input: 'Hello world\nHallo Welt\n${formal.instruction}',
            output: 'Hallo Welt+formal',
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'carries the recent source languages',
      setUp: () {
        stubRefine();
        mocks.stubSettings(
          const AppSettings(
            recentPairs: [LanguagePair(source: fr, target: en)],
          ),
        );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.applySuggestion(formal),
      verify: (_) {
        expect(mocks.refineCalls().single.$1.recentSourceLanguages, ['fr']);
      },
    );
  });

  group('applied refinements are cleared', () {
    Future<TranslateCubit> refinedCubit() async {
      stubRefine();
      mocks.stubTranslate();
      final cubit = mocks.build()..emit(translated());
      addTearDown(cubit.close);
      await cubit.applySuggestion(formal);
      expect(cubit.state.appliedRefinements, hasLength(1));
      return cubit;
    }

    test('when the input changes', () async {
      final cubit = await refinedCubit();
      cubit.setInput('Hello');
      expect(cubit.state.appliedRefinements, isEmpty);
    });

    test('when the options change', () async {
      final cubit = await refinedCubit();
      cubit.setOptions(const TranslationOptions(context: 'chat'));
      expect(cubit.state.appliedRefinements, isEmpty);
    });

    test('when a language changes', () async {
      final cubit = await refinedCubit();
      cubit.setTarget(fr);
      expect(cubit.state.appliedRefinements, isEmpty);
    });

    test('when the engine changes', () async {
      final cubit = await refinedCubit();
      await cubit.selectEngine(google);
      expect(cubit.state.appliedRefinements, isEmpty);
    });

    test('when a new translation runs', () async {
      final cubit = await refinedCubit();
      await cubit.translate();
      expect(cubit.state.appliedRefinements, isEmpty);
      expect(cubit.state.output, 'Hello world->de');
    });

    test('and a refinement in flight is dropped on an edit', () async {
      final controller = stubPendingRefine();
      final cubit = mocks.build()..emit(translated());
      addTearDown(cubit.close);
      unawaited(cubit.applySuggestion(formal));
      cubit.setInput('Hello there');
      expect(cubit.state.pendingRefinement, isNull);
      expect(controller.hasListener, isFalse);
    });
  });

  group('applySuggestion elsewhere', () {
    blocTest<TranslateCubit, TranslateState>(
      'translation-only models translate again with the instruction',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        engine: () => gemma,
        result: () => resultOf('Hallo Welt', engine: gemma),
      ),
      act: (cubit) => cubit.applySuggestion(formal),
      verify: (cubit) {
        verify(() => mocks.repository.translate(gemma, any())).called(1);
        verifyNever(
          () => mocks.repository.refine(
            any(),
            any(),
            currentTranslation: any(named: 'currentTranslation'),
            instruction: any(named: 'instruction'),
          ),
        );
        expect(cubit.state.appliedRefinements, isEmpty);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'Mozhi engines translate again with the assist engine',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        engine: () => google,
        result: () => resultOf('Hallo Welt'),
      ),
      act: (cubit) => cubit.applySuggestion(formal),
      verify: (cubit) {
        verify(() => mocks.repository.translate(claude, any())).called(1);
        expect(cubit.state.appliedRefinements, isEmpty);
        expect(cubit.state.refinesOutput, isFalse);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'a stale output is translated again',
      setUp: () => mocks.stubTranslate(),
      build: () => mocks.build(),
      seed: () => translated().copyWith(input: 'Hello there'),
      act: (cubit) => cubit.applySuggestion(formal),
      verify: (cubit) {
        expect(
          mocks.translateRequests().single.options.instructions,
          formal.instruction,
        );
        expect(cubit.state.output, 'Hello there->de');
      },
    );
  });

  group('loadSuggestions', () {
    blocTest<TranslateCubit, TranslateState>(
      'keeps applied chips a reload no longer lists',
      setUp: () {
        when(() => mocks.repository.getSuggestions(any(), any(), any()))
            .thenAnswer(
              (_) async => const [
                RefinementSuggestion(label: 'Poetic', instruction: 'Rhyme.'),
              ],
            );
      },
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        appliedRefinements: [
          AppliedRefinement(suggestion: _warmer, previous: hallo),
        ],
      ),
      act: (cubit) => cubit.loadSuggestions(),
      verify: (cubit) {
        expect(cubit.state.suggestions.map((s) => s.label), [
          ...RefinementSuggestion.defaults.map((s) => s.label),
          'Warmer',
          'Poetic',
        ]);
      },
    );
  });

  group('output edits', () {
    test('useAlternative and applyVariation cancel a refinement', () async {
      final controller = stubPendingRefine();
      final cubit = mocks.build()..emit(translated());
      addTearDown(cubit.close);

      unawaited(cubit.applySuggestion(formal));
      cubit.useAlternative('Hallo, Welt');
      expect(cubit.state.pendingRefinement, isNull);
      expect(cubit.state.output, 'Hallo, Welt');
      expect(controller.hasListener, isFalse);

      unawaited(cubit.applySuggestion(formal));
      cubit.applyVariation(
        const WordInsight(sourceText: 'world', targetText: 'Welt'),
        'Erde',
      );
      expect(cubit.state.pendingRefinement, isNull);
      expect(cubit.state.output, 'Hallo, Erde');
    });

    blocTest<TranslateCubit, TranslateState>(
      'keep applied refinements; toggling off restores the earlier output',
      setUp: stubRefine,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        await cubit.applySuggestion(formal);
        cubit.useAlternative('Guten Tag, Welt');
        expect(cubit.state.appliedSuggestions, [formal]);
        await cubit.applySuggestion(formal);
      },
      verify: (cubit) => expect(cubit.state.result, hallo),
    );
  });
}

const _warmer = RefinementSuggestion(label: 'Warmer', instruction: 'Warm.');
