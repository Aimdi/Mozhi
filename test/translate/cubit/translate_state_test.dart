import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  group(TranslateState, () {
    test('has sensible defaults', () {
      const state = TranslateState();
      expect(state.enginesStatus, EnginesStatus.initial);
      expect(state.engines, isEmpty);
      expect(state.engine, isNull);
      expect(state.assistEngine, isNull);
      expect(state.sourceLanguages, [Language.auto]);
      expect(state.source, Language.auto);
      expect(state.target, en);
      expect(state.status, TranslateStatus.idle);
      expect(state.suggestions, RefinementSuggestion.defaults);
      expect(state.output, isEmpty);
      expect(state.isAiEngine, isFalse);
      expect(state.hasExtras, isFalse);
      expect(state.canSwap, isTrue);
    });

    test('supports value equality', () {
      expect(const TranslateState(), const TranslateState());
      expect(
        const TranslateState(input: 'a'),
        isNot(const TranslateState(input: 'b')),
      );
    });

    group('copyWith', () {
      test('returns an equal object when nothing changes', () {
        final state = readyState(input: 'hi', result: resultOf('hallo'));
        expect(state.copyWith(), state);
      });

      test('replaces every field', () {
        final result = resultOf('hallo');
        const alternatives = AlternativeTranslations(
          description: 'd',
          alternatives: [Alternative(text: 'a')],
        );
        const insight = WordInsight(sourceText: 's', targetText: 't');
        const dictionary = DictionaryEntry(word: 'w');
        const suggestion = RefinementSuggestion(label: 'l', instruction: 'i');
        final entry = CompareEntry.success(result);
        final error = Exception('e');
        final extraError = Exception('x');
        const options = TranslationOptions(context: 'ctx');

        final state = const TranslateState().copyWith(
          enginesStatus: EnginesStatus.ready,
          engines: allEngines,
          engine: () => google,
          assistEngine: () => claude,
          sourceLanguages: sources,
          targetLanguages: targets,
          source: de,
          target: fr,
          input: 'input',
          options: options,
          status: TranslateStatus.success,
          result: () => result,
          resultInput: () => 'old input',
          inputTruncated: true,
          error: () => error,
          compareMode: true,
          compareEntries: [entry],
          comparing: true,
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => alternatives,
          alternativesSpan: () => 'span',
          alternativesSpanStart: () => 3,
          insightsStatus: ExtraStatus.loading,
          insights: [insight],
          suggestionsStatus: ExtraStatus.failure,
          suggestions: [suggestion],
          explainStatus: ExtraStatus.ready,
          explanation: 'md',
          dictionaryStatus: ExtraStatus.ready,
          dictionary: () => dictionary,
          extraError: () => extraError,
        );

        expect(state.enginesStatus, EnginesStatus.ready);
        expect(state.engines, allEngines);
        expect(state.engine, google);
        expect(state.assistEngine, claude);
        expect(state.sourceLanguages, sources);
        expect(state.targetLanguages, targets);
        expect(state.source, de);
        expect(state.target, fr);
        expect(state.input, 'input');
        expect(state.options, options);
        expect(state.status, TranslateStatus.success);
        expect(state.result, same(result));
        expect(state.resultInput, 'old input');
        expect(state.inputTruncated, isTrue);
        expect(state.error, same(error));
        expect(state.compareMode, isTrue);
        expect(state.compareEntries, [entry]);
        expect(state.comparing, isTrue);
        expect(state.alternativesStatus, ExtraStatus.ready);
        expect(state.alternatives, same(alternatives));
        expect(state.alternativesSpan, 'span');
        expect(state.alternativesSpanStart, 3);
        expect(state.insightsStatus, ExtraStatus.loading);
        expect(state.insights, [insight]);
        expect(state.suggestionsStatus, ExtraStatus.failure);
        expect(state.suggestions, [suggestion]);
        expect(state.explainStatus, ExtraStatus.ready);
        expect(state.explanation, 'md');
        expect(state.dictionaryStatus, ExtraStatus.ready);
        expect(state.dictionary, same(dictionary));
        expect(state.extraError, same(extraError));
      });

      test('can reset nullable fields to null', () {
        final state = const TranslateState()
            .copyWith(
              engine: () => google,
              assistEngine: () => claude,
              result: () => resultOf('x'),
              error: () => 'e',
              alternatives: () => const AlternativeTranslations(
                description: '',
                alternatives: [],
              ),
              alternativesSpan: () => 's',
              alternativesSpanStart: () => 1,
              dictionary: () => const DictionaryEntry(word: 'w'),
              extraError: () => 'x',
            )
            .copyWith(
              engine: () => null,
              assistEngine: () => null,
              result: () => null,
              error: () => null,
              alternatives: () => null,
              alternativesSpan: () => null,
              alternativesSpanStart: () => null,
              dictionary: () => null,
              extraError: () => null,
            );
        expect(state, const TranslateState());
      });
    });

    group('resultInput', () {
      test('is dropped together with the result', () {
        final state = readyState(input: 'a', result: resultOf('x'));
        expect(state.resultInput, 'a');
        expect(state.copyWith(result: () => null).resultInput, isNull);
        expect(state.copyWith(input: 'b').resultInput, 'a');
        expect(state.copyWith(result: () => resultOf('y')).resultInput, 'a');
        expect(
          state
              .copyWith(result: () => null, resultInput: () => 'kept')
              .resultInput,
          'kept',
        );
      });

      test('isResultStale compares it with the input', () {
        expect(
          readyState(input: 'a', result: resultOf('x')).isResultStale,
          isFalse,
        );
        expect(
          readyState(
            input: 'b',
            result: resultOf('x'),
            resultInput: 'a',
          ).isResultStale,
          isTrue,
        );
        // Unknown origin or no result: not stale.
        expect(
          TranslateState(input: 'b', result: resultOf('x')).isResultStale,
          isFalse,
        );
        expect(const TranslateState(input: 'b').isResultStale, isFalse);
      });
    });

    test('defaults for the input flags', () {
      const state = TranslateState();
      expect(state.inputTruncated, isFalse);
      expect(state.resultInput, isNull);
      expect(state.alternativesSpanStart, isNull);
    });

    test('output is the result text', () {
      expect(readyState(result: resultOf('hallo')).output, 'hallo');
    });

    test('isAiEngine and hasExtras follow the engines', () {
      expect(readyState(engine: claude).isAiEngine, isTrue);
      expect(readyState().isAiEngine, isFalse);
      expect(readyState().hasExtras, isTrue);
      expect(readyState(assistEngine: null).hasExtras, isFalse);
    });

    test('canSwap is false for custom targets', () {
      expect(readyState(target: pirate).canSwap, isFalse);
    });

    test('effectiveSourceCode uses the detected language for auto', () {
      expect(
        readyState(result: resultOf('x', detected: 'de')).effectiveSourceCode,
        'de',
      );
      expect(readyState().effectiveSourceCode, isNull);
      expect(
        readyState(
          source: fr,
          result: resultOf('x', detected: 'de'),
        ).effectiveSourceCode,
        'fr',
      );
    });

    test('isShortInput is true for 1-3 words', () {
      expect(readyState(input: 'hello').isShortInput, isTrue);
      expect(readyState(input: ' one two  three ').isShortInput, isTrue);
      expect(readyState(input: 'one two three four').isShortInput, isFalse);
      expect(readyState(input: '   ').isShortInput, isFalse);
    });

    group('round 3', () {
      const formal = RefinementSuggestion(label: 'f', instruction: 'i');
      const span = AlignedSpan(
        sourceStart: 0,
        sourceEnd: 1,
        targetStart: 0,
        targetEnd: 1,
      );
      const notice = SmartSwapNotice(id: 1, previousTarget: en, newTarget: es);

      test('has sensible defaults', () {
        const state = TranslateState();
        expect(state.appliedRefinements, isEmpty);
        expect(state.pendingRefinement, isNull);
        expect(state.isRefining, isFalse);
        expect(state.refinementError, isNull);
        expect(state.romanizationStatus, ExtraStatus.idle);
        expect(state.romanization, isNull);
        expect(state.alignmentStatus, ExtraStatus.idle);
        expect(state.alignment, isEmpty);
        expect(state.alignmentFocus, isNull);
        expect(state.focusedAlignment, isNull);
        expect(state.smartSwapNotice, isNull);
        expect(state.dictionaryVerbosity, DictionaryVerbosity.standard);
        expect(state.dictionaryQuery, isNull);
        expect(state.qualityMode, QualityMode.off);
        expect(state.hasQualityModes, isFalse);
        expect(state.availableQualityModes, [QualityMode.off]);
        expect(state.supportsCustomLanguages, isFalse);
      });

      test('copyWith replaces and resets the new fields', () {
        final result = resultOf('x');
        final error = Exception('e');
        final applied = AppliedRefinement(suggestion: formal, previous: result);
        final state = const TranslateState().copyWith(
          appliedRefinements: [applied],
          pendingRefinement: () => formal,
          refinementError: () => error,
          romanizationStatus: ExtraStatus.ready,
          romanization: () => 'r',
          romanizationError: () => error,
          alignmentStatus: ExtraStatus.ready,
          alignment: const [span],
          alignmentFocus: () => 0,
          alignmentError: () => error,
          smartSwapNotice: () => notice,
          dictionaryVerbosity: DictionaryVerbosity.concise,
          dictionaryQuery: () => 'w',
          qualityMode: QualityMode.best,
          fastEngine: () => deepl,
          bestEngine: () => claude,
        );
        expect(state.appliedRefinements, [applied]);
        expect(state.appliedSuggestions, [formal]);
        expect(state.isSuggestionApplied(formal), isTrue);
        expect(state.pendingRefinement, formal);
        expect(state.isRefining, isTrue);
        expect(state.refinementError, same(error));
        expect(state.romanizationStatus, ExtraStatus.ready);
        expect(state.romanization, 'r');
        expect(state.romanizationError, same(error));
        expect(state.alignmentStatus, ExtraStatus.ready);
        expect(state.alignment, [span]);
        expect(state.alignmentFocus, 0);
        expect(state.focusedAlignment, span);
        expect(state.alignmentError, same(error));
        expect(state.smartSwapNotice, notice);
        expect(state.dictionaryVerbosity, DictionaryVerbosity.concise);
        expect(state.dictionaryQuery, 'w');
        expect(state.qualityMode, QualityMode.best);
        expect(state.fastEngine, deepl);
        expect(state.bestEngine, claude);
        expect(state.copyWith(), state);

        final reset = state.copyWith(
          appliedRefinements: const [],
          pendingRefinement: () => null,
          refinementError: () => null,
          romanizationStatus: ExtraStatus.idle,
          romanization: () => null,
          romanizationError: () => null,
          alignmentStatus: ExtraStatus.idle,
          alignment: const [],
          alignmentFocus: () => null,
          alignmentError: () => null,
          smartSwapNotice: () => null,
          dictionaryVerbosity: DictionaryVerbosity.standard,
          dictionaryQuery: () => null,
          qualityMode: QualityMode.off,
          fastEngine: () => null,
          bestEngine: () => null,
        );
        expect(reset, const TranslateState());
      });

      test('AppliedRefinement and SmartSwapNotice compare by value', () {
        expect(
          AppliedRefinement(suggestion: formal, previous: resultOf('x')),
          AppliedRefinement(suggestion: formal, previous: resultOf('x')),
        );
        expect(
          AppliedRefinement(suggestion: formal, previous: resultOf('x')),
          isNot(AppliedRefinement(suggestion: formal, previous: resultOf('y'))),
        );
        expect(
          notice,
          const SmartSwapNotice(id: 1, previousTarget: en, newTarget: es),
        );
        expect(
          notice,
          isNot(
            const SmartSwapNotice(id: 2, previousTarget: en, newTarget: es),
          ),
        );
      });

      test('refinesOutput needs a general AI engine and a finished output', () {
        final done = readyState(
          engine: claude,
          input: 'hi',
          result: resultOf('hallo', engine: claude),
          status: TranslateStatus.success,
        );
        expect(done.refinesOutput, isTrue);
        expect(done.copyWith(engine: () => gemma).refinesOutput, isFalse);
        expect(done.copyWith(engine: () => google).refinesOutput, isFalse);
        expect(
          done.copyWith(status: TranslateStatus.translating).refinesOutput,
          isFalse,
        );
        expect(done.copyWith(input: 'hey').refinesOutput, isFalse);
        expect(
          done.copyWith(result: () => resultOf(' ')).refinesOutput,
          isFalse,
        );
      });

      test('qualityEngine names the engine of each mode', () {
        final state = const TranslateState().copyWith(fastEngine: () => deepl);
        expect(state.qualityEngine(QualityMode.fast), deepl);
        expect(state.qualityEngine(QualityMode.best), isNull);
        expect(state.qualityEngine(QualityMode.off), isNull);
        expect(state.hasQualityModes, isTrue);
        expect(state.availableQualityModes, [
          QualityMode.off,
          QualityMode.fast,
        ]);
      });
    });
  });
}
