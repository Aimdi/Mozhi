import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() {
    mocks = TranslateMocks();
  });

  final hallo = resultOf('Hallo Welt', detected: 'en');

  /// Translated "Hello world" (auto, detected English) to German.
  TranslateState translated() => readyState(
    input: 'Hello world',
    target: de,
    result: hallo,
    status: TranslateStatus.success,
  );

  const expectedRequest = TranslationRequest(
    text: 'Hello world',
    source: en,
    target: de,
  );

  final extraError = Exception('rate limited');

  group('preconditions', () {
    blocTest<TranslateCubit, TranslateState>(
      'extras do nothing without an assist engine',
      build: () => mocks.build(),
      seed: () => translated().copyWith(assistEngine: () => null),
      act: (cubit) async {
        await cubit.loadAlternatives();
        await cubit.loadInsights();
        await cubit.loadSuggestions();
        await cubit.explain();
        await cubit.lookUp();
      },
      expect: () => <TranslateState>[],
    );

    blocTest<TranslateCubit, TranslateState>(
      'translation extras need a finished, non-empty translation',
      build: () => mocks.build(),
      act: (cubit) async {
        cubit.emit(translated().copyWith(result: () => null));
        await cubit.loadAlternatives();
        cubit.emit(
          translated().copyWith(
            result: () => resultOf('Hal', isComplete: false),
          ),
        );
        await cubit.loadInsights();
        cubit.emit(translated().copyWith(result: () => resultOf(' ')));
        await cubit.loadSuggestions();
        cubit.emit(translated().copyWith(input: ' '));
        await cubit.explain();
        await cubit.lookUp();
      },
      skip: 4,
      expect: () => <TranslateState>[],
      verify: (_) => verifyZeroInteractions(mocks.repository),
    );
  });

  group('loadAlternatives', () {
    const alternatives = AlternativeTranslations(
      description: 'Neutral register.',
      alternatives: [Alternative(text: 'Hallo, Welt', explanation: 'comma')],
    );

    blocTest<TranslateCubit, TranslateState>(
      'loads alternatives for a span with the detected source',
      setUp: () {
        when(
          () => mocks.repository.getAlternatives(
            any(),
            any(),
            any(),
            span: any(named: 'span'),
          ),
        ).thenAnswer((_) async => alternatives);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadAlternatives(span: 'Welt'),
      expect: () => [
        translated().copyWith(
          alternativesStatus: ExtraStatus.loading,
          alternativesSpan: () => 'Welt',
        ),
        translated().copyWith(
          alternativesStatus: ExtraStatus.ready,
          alternativesSpan: () => 'Welt',
          alternatives: () => alternatives,
        ),
      ],
      verify: (_) {
        verify(
          () => mocks.repository.getAlternatives(
            claude,
            expectedRequest,
            'Hallo Welt',
            span: 'Welt',
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure with the error',
      setUp: () {
        when(
          () => mocks.repository.getAlternatives(
            any(),
            any(),
            any(),
            span: any(named: 'span'),
          ),
        ).thenThrow(extraError);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadAlternatives(),
      expect: () => [
        translated().copyWith(alternativesStatus: ExtraStatus.loading),
        translated().copyWith(
          alternativesStatus: ExtraStatus.failure,
          extraError: () => extraError,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores results that arrive after the input changed',
      setUp: () {
        when(
          () => mocks.repository.getAlternatives(
            any(),
            any(),
            any(),
            span: any(named: 'span'),
          ),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return alternatives;
        });
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final done = cubit.loadAlternatives();
        cubit.clearExtras();
        await done;
      },
      expect: () => [
        translated().copyWith(alternativesStatus: ExtraStatus.loading),
        translated(),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores failures that arrive after the input changed',
      setUp: () {
        when(
          () => mocks.repository.getAlternatives(
            any(),
            any(),
            any(),
            span: any(named: 'span'),
          ),
        ).thenAnswer((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw extraError;
        });
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final done = cubit.loadAlternatives();
        cubit.clearExtras();
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.alternativesStatus, ExtraStatus.idle);
        expect(cubit.state.extraError, isNull);
      },
    );
  });

  group('loadInsights', () {
    const insight = WordInsight(sourceText: 'world', targetText: 'Welt');

    blocTest<TranslateCubit, TranslateState>(
      'loads insights',
      setUp: () {
        when(() => mocks.repository.getInsights(any(), any(), any()))
            .thenAnswer((_) async => [insight]);
      },
      build: () => mocks.build(),
      seed: () => translated().copyWith(extraError: () => 'old'),
      act: (cubit) => cubit.loadInsights(),
      expect: () => [
        translated().copyWith(insightsStatus: ExtraStatus.loading),
        translated().copyWith(
          insightsStatus: ExtraStatus.ready,
          insights: [insight],
        ),
      ],
      verify: (_) {
        verify(
          () => mocks.repository.getInsights(
            claude,
            expectedRequest,
            'Hallo Welt',
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure with the error',
      setUp: () {
        when(() => mocks.repository.getInsights(any(), any(), any()))
            .thenAnswer((_) async => throw extraError);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadInsights(),
      verify: (cubit) {
        expect(cubit.state.insightsStatus, ExtraStatus.failure);
        expect(cubit.state.extraError, extraError);
      },
    );
  });

  group('loadSuggestions', () {
    const pirateSuggestion = RefinementSuggestion(
      label: 'Pirate-ify',
      instruction: 'Talk like a pirate.',
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps the defaults first and appends unique suggestions',
      setUp: () {
        when(
          () => mocks.repository.getSuggestions(any(), any(), any()),
        ).thenAnswer(
          (_) async => [
            const RefinementSuggestion(label: 'more FORMAL', instruction: 'x'),
            RefinementSuggestion(
              label: 'Other',
              instruction: RefinementSuggestion.defaults.first.instruction,
            ),
            const RefinementSuggestion(label: ' ', instruction: 'y'),
            const RefinementSuggestion(label: 'Empty', instruction: ''),
            pirateSuggestion,
            const RefinementSuggestion(
              label: 'pirate-ify',
              instruction: 'Again.',
            ),
          ],
        );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadSuggestions(),
      expect: () => [
        translated().copyWith(suggestionsStatus: ExtraStatus.loading),
        translated().copyWith(
          suggestionsStatus: ExtraStatus.ready,
          suggestions: [...RefinementSuggestion.defaults, pirateSuggestion],
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure with the error',
      setUp: () {
        when(() => mocks.repository.getSuggestions(any(), any(), any()))
            .thenThrow(extraError);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.loadSuggestions(),
      verify: (cubit) {
        expect(cubit.state.suggestionsStatus, ExtraStatus.failure);
        expect(cubit.state.suggestions, RefinementSuggestion.defaults);
        expect(cubit.state.extraError, extraError);
      },
    );
  });

  group('explain', () {
    blocTest<TranslateCubit, TranslateState>(
      'streams the explanation',
      setUp: () {
        when(
          () => mocks.repository.explain(
            any(),
            any(),
            any(),
            question: any(named: 'question'),
          ),
        ).thenAnswer((_) => Stream.fromIterable(['**Welt**', ' means world.']));
      },
      build: () => mocks.build(),
      seed: () => translated().copyWith(explanation: 'old'),
      act: (cubit) => cubit.explain(question: 'Why Welt?'),
      expect: () => [
        translated().copyWith(explainStatus: ExtraStatus.loading),
        translated().copyWith(
          explainStatus: ExtraStatus.loading,
          explanation: '**Welt**',
        ),
        translated().copyWith(
          explainStatus: ExtraStatus.loading,
          explanation: '**Welt** means world.',
        ),
        translated().copyWith(
          explainStatus: ExtraStatus.ready,
          explanation: '**Welt** means world.',
        ),
      ],
      verify: (_) {
        verify(
          () => mocks.repository.explain(
            claude,
            expectedRequest,
            'Hallo Welt',
            question: 'Why Welt?',
          ),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure on a stream error',
      setUp: () {
        when(
          () => mocks.repository.explain(
            any(),
            any(),
            any(),
            question: any(named: 'question'),
          ),
        ).thenAnswer((_) async* {
          yield 'Partial';
          throw extraError;
        });
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.explain(),
      verify: (cubit) {
        expect(cubit.state.explainStatus, ExtraStatus.failure);
        expect(cubit.state.explanation, 'Partial');
        expect(cubit.state.extraError, extraError);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure when the repository throws',
      setUp: () {
        when(
          () => mocks.repository.explain(
            any(),
            any(),
            any(),
            question: any(named: 'question'),
          ),
        ).thenThrow(extraError);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.explain(),
      expect: () => [
        translated().copyWith(explainStatus: ExtraStatus.loading),
        translated().copyWith(
          explainStatus: ExtraStatus.failure,
          extraError: () => extraError,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'a new question replaces the running explanation',
      setUp: () {
        final first = StreamController<String>();
        var calls = 0;
        when(
          () => mocks.repository.explain(
            any(),
            any(),
            any(),
            question: any(named: 'question'),
          ),
        ).thenAnswer((_) {
          calls++;
          return calls == 1 ? first.stream : Stream.value('Second.');
        });
        unawaited(
          Future<void>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            expect(first.hasListener, isFalse);
            first.add('First.');
          }),
        );
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final firstDone = cubit.explain();
        await cubit.explain(question: 'Another?');
        await firstDone;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
      verify: (cubit) {
        expect(cubit.state.explanation, 'Second.');
        expect(cubit.state.explainStatus, ExtraStatus.ready);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'typing cancels the explanation',
      setUp: () {
        when(
          () => mocks.repository.explain(
            any(),
            any(),
            any(),
            question: any(named: 'question'),
          ),
        ).thenAnswer((_) => StreamController<String>().stream);
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final done = cubit.explain();
        cubit.setInput('Hello');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.explainStatus, ExtraStatus.idle);
        expect(cubit.state.explanation, isEmpty);
      },
    );
  });

  group('lookUp', () {
    const entry = DictionaryEntry(word: 'Hallo', pronunciation: 'haˈloː');

    blocTest<TranslateCubit, TranslateState>(
      'looks up the trimmed input with the detected source',
      setUp: () {
        when(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenAnswer((_) async => entry);
      },
      build: () => mocks.build(),
      seed: () => readyState(
        input: ' Hallo ',
        result: resultOf('Hello', detected: 'de'),
        status: TranslateStatus.success,
      ),
      act: (cubit) => cubit.lookUp(),
      expect: () => [
        isA<TranslateState>().having(
          (s) => s.dictionaryStatus,
          'dictionaryStatus',
          ExtraStatus.loading,
        ),
        isA<TranslateState>()
            .having(
              (s) => s.dictionaryStatus,
              'dictionaryStatus',
              ExtraStatus.ready,
            )
            .having((s) => s.dictionary, 'dictionary', entry),
      ],
      verify: (_) {
        verify(
          () =>
              mocks.repository.lookUp(claude, 'Hallo', source: de, target: en),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the selected source and works before translating',
      setUp: () {
        when(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenAnswer((_) async => entry);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo', source: de, target: fr),
      act: (cubit) => cubit.lookUp(),
      verify: (cubit) {
        expect(cubit.state.dictionary, entry);
        verify(
          () =>
              mocks.repository.lookUp(claude, 'Hallo', source: de, target: fr),
        ).called(1);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'keeps auto when nothing was detected and keeps unknown detections',
      setUp: () {
        when(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenAnswer((_) async => entry);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        await cubit.lookUp();
        cubit.emit(
          cubit.state.copyWith(result: () => resultOf('x', detected: 'ja')),
        );
        await cubit.lookUp();
      },
      verify: (_) {
        final sources = verify(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: captureAny(named: 'source'),
            target: any(named: 'target'),
          ),
        ).captured;
        expect(sources, [
          Language.auto,
          const Language(code: 'ja', name: 'ja'),
        ]);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'emits failure with the error',
      setUp: () {
        when(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenThrow(extraError);
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) => cubit.lookUp(),
      expect: () => [
        readyState(input: 'Hallo').copyWith(
          dictionaryStatus: ExtraStatus.loading,
          dictionaryQuery: () => 'Hallo',
        ),
        readyState(input: 'Hallo').copyWith(
          dictionaryStatus: ExtraStatus.failure,
          dictionaryQuery: () => 'Hallo',
          extraError: () => extraError,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores stale results and failures',
      setUp: () {
        mocks.stubTranslate();
        var calls = 0;
        when(
          () => mocks.repository.lookUp(
            any(),
            any(),
            source: any(named: 'source'),
            target: any(named: 'target'),
          ),
        ).thenAnswer((_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (calls == 1) return entry;
          throw extraError;
        });
      },
      build: () => mocks.build(),
      seed: () => readyState(input: 'Hallo'),
      act: (cubit) async {
        final first = cubit.lookUp();
        cubit.setInput('Hallo!');
        await first;
        final second = cubit.lookUp();
        cubit.clearExtras();
        await second;
      },
      verify: (cubit) {
        expect(cubit.state.dictionaryStatus, ExtraStatus.idle);
        expect(cubit.state.dictionary, isNull);
        expect(cubit.state.extraError, isNull);
      },
    );
  });

  group('clearExtras', () {
    blocTest<TranslateCubit, TranslateState>(
      'resets every extra',
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        alternativesStatus: ExtraStatus.ready,
        alternatives: () =>
            const AlternativeTranslations(description: '', alternatives: []),
        alternativesSpan: () => 'Welt',
        insightsStatus: ExtraStatus.ready,
        insights: const [WordInsight(sourceText: 'a', targetText: 'b')],
        suggestionsStatus: ExtraStatus.ready,
        suggestions: const [],
        explainStatus: ExtraStatus.failure,
        explanation: 'md',
        dictionaryStatus: ExtraStatus.ready,
        dictionary: () => const DictionaryEntry(word: 'w'),
        extraError: () => 'x',
      ),
      act: (cubit) => cubit.clearExtras(),
      expect: () => [translated()],
    );
  });
}
