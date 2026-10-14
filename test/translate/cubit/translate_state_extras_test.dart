import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

void main() {
  group('ExtraTranslation', () {
    const request = TranslationRequest(
      text: 'Hello',
      source: Language.auto,
      target: fr,
    );
    final translation = ExtraTranslation(
      target: fr,
      status: TranslateStatus.success,
      result: resultOf('Bonjour'),
      request: request,
      engineId: google.id,
    );

    test('knows its output and the input it belongs to', () {
      expect(translation.output, 'Bonjour');
      expect(translation.resultInput, 'Hello');
      expect(translation.isStaleFor('Hello'), isFalse);
      expect(translation.isStaleFor('Hello there'), isTrue);
    });

    test('without a result has no output and is never stale', () {
      const pending = ExtraTranslation(target: fr, request: request);
      expect(pending.status, TranslateStatus.idle);
      expect(pending.output, isEmpty);
      expect(pending.resultInput, isNull);
      expect(pending.isStaleFor('Other'), isFalse);
    });

    test('copyWith replaces and clears fields', () {
      final error = Exception('x');
      final failed = translation.copyWith(
        status: TranslateStatus.failure,
        result: () => null,
        error: () => error,
      );
      expect(failed.target, fr);
      expect(failed.status, TranslateStatus.failure);
      expect(failed.result, isNull);
      expect(failed.error, error);
      expect(failed.request, request);
      expect(failed.engineId, google.id);
      expect(
        failed.copyWith(request: () => null, engineId: () => null),
        ExtraTranslation(
          target: fr,
          status: TranslateStatus.failure,
          error: error,
        ),
      );
      expect(translation.copyWith(), translation);
    });
  });

  group('TranslateState', () {
    test('copyWith sets and clears the new fields', () {
      const check = MeaningCheck(verdict: MeaningVerdict.same);
      final error = Exception('x');
      final translations = [const ExtraTranslation(target: fr)];
      final state = const TranslateState().copyWith(
        meaningStatus: ExtraStatus.ready,
        meaningCheck: () => check,
        backTranslation: () => 'Hi',
        meaningFocus: () => 0,
        meaningError: () => error,
        extraTargets: const [fr],
        extraTranslations: translations,
      );
      expect(state.meaningStatus, ExtraStatus.ready);
      expect(state.meaningCheck, check);
      expect(state.backTranslation, 'Hi');
      expect(state.meaningFocus, 0);
      expect(state.meaningError, error);
      expect(state.extraTargets, const [fr]);
      expect(state.extraTranslations, translations);
      expect(state.copyWith(), state);
      expect(state, isNot(const TranslateState()));
      expect(
        state.copyWith(
          meaningStatus: ExtraStatus.idle,
          meaningCheck: () => null,
          backTranslation: () => null,
          meaningFocus: () => null,
          meaningError: () => null,
          extraTargets: const [],
          extraTranslations: const [],
        ),
        const TranslateState(),
      );
    });

    group('canCheckMeaning', () {
      TranslateState translated({
        TranslationEngine engine = google,
        TranslationEngine? assistEngine = claude,
        Language source = Language.auto,
        String? detected = 'en',
      }) => readyState(
        engine: engine,
        assistEngine: assistEngine,
        input: 'Hello',
        source: source,
        target: de,
        result: resultOf('Hallo', detected: detected),
        status: TranslateStatus.success,
      );

      test('is true for a finished output with an AI extras engine', () {
        final state = translated(detected: null);
        expect(state.meaningUsesAi, isTrue);
        expect(state.canCheckMeaning, isTrue);
      });

      test('needs a known source language for a back-translation', () {
        expect(translated(assistEngine: null).canCheckMeaning, isTrue);
        expect(
          translated(assistEngine: gemma, detected: null).meaningUsesAi,
          isFalse,
        );
        expect(
          translated(assistEngine: null, detected: null).canCheckMeaning,
          isFalse,
        );
        expect(
          translated(assistEngine: null, detected: ' ').canCheckMeaning,
          isFalse,
        );
        expect(
          translated(
            assistEngine: null,
            source: en,
            detected: null,
          ).canCheckMeaning,
          isTrue,
        );
      });

      test('needs an engine for a back-translation', () {
        expect(
          translated(assistEngine: null)
              .copyWith(engine: () => null)
              .canCheckMeaning,
          isFalse,
        );
      });

      test('is false while translating', () {
        expect(
          translated()
              .copyWith(status: TranslateStatus.translating)
              .canCheckMeaning,
          isFalse,
        );
      });
    });

    test('focusedMeaningIssue is the issue at the focus', () {
      const issue = MeaningIssue(problem: 'p');
      final state = const TranslateState().copyWith(
        meaningCheck: () =>
            const MeaningCheck(verdict: MeaningVerdict.minor, issues: [issue]),
      );
      expect(state.focusedMeaningIssue, isNull);
      expect(state.copyWith(meaningFocus: () => 0).focusedMeaningIssue, issue);
      expect(state.copyWith(meaningFocus: () => 1).focusedMeaningIssue, isNull);
      expect(
        state.copyWith(meaningFocus: () => -1).focusedMeaningIssue,
        isNull,
      );
      expect(const TranslateState(meaningFocus: 0).focusedMeaningIssue, isNull);
    });

    group('activeExtraTargets', () {
      test('maps picks onto the engine list without duplicates', () {
        final state = readyState(target: de).copyWith(
          extraTargets: const [
            Language(code: 'fr-FR', name: 'French (France)'),
            fr,
            es,
          ],
        );
        expect(state.activeExtraTargets, const [fr, es]);
        expect(state.isExtraTarget(fr), isTrue);
        expect(state.isExtraTarget(en), isFalse);
      });

      test('keeps custom languages for engines that take them', () {
        final onClaude = readyState(
          engine: claude,
          target: de,
        ).copyWith(extraTargets: const [pirate, de]);
        expect(onClaude.activeExtraTargets, const [pirate]);
        expect(onClaude.isExtraTarget(pirate), isTrue);
        final onGoogle = onClaude.copyWith(engine: () => google);
        expect(onGoogle.activeExtraTargets, isEmpty);
      });

      test('leaves out a custom source', () {
        final state = readyState(
          engine: claude,
          source: pirate,
          target: de,
        ).copyWith(extraTargets: const [pirate, fr]);
        expect(state.activeExtraTargets, const [fr]);
      });

      test('leaves out the language detected in the input', () {
        final state = readyState(
          input: 'Hello there',
          target: de,
          result: resultOf('Hallo', detected: 'EN'),
        ).copyWith(extraTargets: const [en, fr]);
        expect(state.detectedInputLanguage, 'EN');
        expect(state.activeExtraTargets, const [fr]);
        // Also while the result belongs to an earlier version of the input.
        expect(
          state.copyWith(input: 'Hello there, friend').activeExtraTargets,
          const [fr],
        );
      });

      test('keeps the detected language when the detection is not final', () {
        final translated = readyState(
          input: 'Hello',
          target: de,
          result: resultOf('Hallo', detected: 'en'),
        ).copyWith(extraTargets: const [en, fr]);
        for (final state in [
          translated.copyWith(
            result: () => resultOf('Hal', detected: 'en', isComplete: false),
          ),
          translated.copyWith(
            result: () => resultOf(
              'Hallo',
              detected: 'en',
            ).copyWith(detectionUncertain: true),
          ),
          translated.copyWith(result: () => resultOf('Hallo', detected: ' ')),
          translated.copyWith(result: () => null),
          translated.copyWith(source: es),
        ]) {
          expect(state.detectedInputLanguage, isNull);
          expect(state.activeExtraTargets, contains(en));
        }
      });
    });

    group('unavailableExtraTargets', () {
      test('are the picks the engine does not offer, in pick order', () {
        final onGoogle = readyState(target: de)
            .copyWith(extraTargets: const [ja, fr, pirate, de]);
        expect(onGoogle.unavailableExtraTargets, const [ja, pirate]);
        // The main target is offered: it is skipped, not unavailable.
        expect(
          onGoogle.copyWith(engine: () => claude).unavailableExtraTargets,
          const [ja],
        );
      });

      test('are none before the engine and its languages are loaded', () {
        final state = readyState().copyWith(extraTargets: const [ja, pirate]);
        expect(
          state.copyWith(engine: () => null).unavailableExtraTargets,
          isEmpty,
        );
        expect(
          state.copyWith(targetLanguages: const []).unavailableExtraTargets,
          isEmpty,
        );
      });
    });

    test('extraTranslationFor finds the translation into a language', () {
      const french = ExtraTranslation(target: fr);
      final state = const TranslateState().copyWith(
        extraTranslations: const [french],
      );
      expect(state.extraTranslationFor(fr), french);
      expect(state.extraTranslationFor(es), isNull);
    });
  });
}
