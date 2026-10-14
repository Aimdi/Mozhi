import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import 'translate_cubit_helpers.dart';

class _MockUsageTracker extends Mock implements UsageTracker;

void main() {
  setUpAll(registerTranslateFallbacks);

  late TranslateMocks mocks;

  setUp(() => mocks = TranslateMocks());

  final hallo = resultOf('Hallo Welt', detected: 'en');

  /// "Hello world" -> "Hallo Welt" (detected English) on Google, Claude as
  /// the assist engine.
  TranslateState translated({
    TranslationEngine engine = google,
    TranslationEngine? assistEngine = claude,
    Language source = Language.auto,
    TranslationResult? result,
  }) => readyState(
    engine: engine,
    assistEngine: assistEngine,
    input: 'Hello world',
    source: source,
    target: de,
    result: result ?? hallo,
    status: TranslateStatus.success,
  );

  const issue = MeaningIssue(
    problem: 'The greeting is missing.',
    type: MeaningIssueType.omission,
    sourceSpan: 'Hello',
    translationSpan: 'Hallo',
    suggestion: 'Hallo',
    sourceStart: 0,
    sourceEnd: 5,
    translationStart: 0,
    translationEnd: 5,
  );
  const check = MeaningCheck(
    verdict: MeaningVerdict.minor,
    backTranslation: 'Hello world',
    issues: [
      issue,
      MeaningIssue(problem: 'Second'),
    ],
  );

  void stubCheck({Future<MeaningCheck> Function()? answer}) {
    when(
      () => mocks.repository.checkMeaning(
        any(),
        source: any(named: 'source'),
        translation: any(named: 'translation'),
        sourceLanguage: any(named: 'sourceLanguage'),
        targetLanguage: any(named: 'targetLanguage'),
        uiLanguage: any(named: 'uiLanguage'),
      ),
    ).thenAnswer((_) => answer?.call() ?? Future.value(check));
  }

  void stubBackTranslate({
    TranslationResult? result,
    Future<TranslationResult> Function()? answer,
  }) {
    when(
      () => mocks.repository.backTranslateResult(
        any(),
        translation: any(named: 'translation'),
        from: any(named: 'from'),
        to: any(named: 'to'),
      ),
    ).thenAnswer(
      (_) =>
          answer?.call() ??
          Future.value(result ?? resultOf('Hello world', engine: gemma)),
    );
  }

  void verifyNoRequests() {
    verifyNever(
      () => mocks.repository.checkMeaning(
        any(),
        source: any(named: 'source'),
        translation: any(named: 'translation'),
        sourceLanguage: any(named: 'sourceLanguage'),
        targetLanguage: any(named: 'targetLanguage'),
        uiLanguage: any(named: 'uiLanguage'),
      ),
    );
    verifyNever(
      () => mocks.repository.backTranslateResult(
        any(),
        translation: any(named: 'translation'),
        from: any(named: 'from'),
        to: any(named: 'to'),
      ),
    );
  }

  _MockUsageTracker trackUsage() {
    final tracker = _MockUsageTracker();
    when(
      () => tracker.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async => const UsageStats(requests: 1));
    mocks.usageTracker = tracker;
    return tracker;
  }

  group('checkMeaning with an AI extras engine', () {
    blocTest<TranslateCubit, TranslateState>(
      'checks the input and the output with the detected source',
      setUp: stubCheck,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.checkMeaning(uiLanguage: 'German'),
      expect: () => [
        translated().copyWith(meaningStatus: ExtraStatus.loading),
        translated().copyWith(
          meaningStatus: ExtraStatus.ready,
          meaningCheck: () => check,
        ),
      ],
      verify: (cubit) {
        verify(
          () => mocks.repository.checkMeaning(
            claude,
            source: 'Hello world',
            translation: 'Hallo Welt',
            sourceLanguage: en,
            targetLanguage: de,
            uiLanguage: 'German',
          ),
        ).called(1);
        expect(cubit.state.meaningUsesAi, isTrue);
        expect(cubit.state.backTranslation, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses English for the problems by default',
      setUp: stubCheck,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.checkMeaning(),
      verify: (_) => expect(
        verify(
          () => mocks.repository.checkMeaning(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
            uiLanguage: captureAny(named: 'uiLanguage'),
          ),
        ).captured,
        ['English'],
      ),
    );

    blocTest<TranslateCubit, TranslateState>(
      'counts the request as provider usage',
      setUp: () {
        stubCheck();
        trackUsage();
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.checkMeaning(),
      verify: (_) => verify(
        () => mocks.usageTracker!.recordText(
          'claude',
          input: 'Hello world\nHallo Welt',
          output: [
            'minor',
            'Hello world',
            'Hello',
            'Hallo',
            'The greeting is missing.',
            'Hallo',
            '',
            '',
            'Second',
            '',
          ].join('\n'),
        ),
      ).called(1),
    );

    final failure = Exception('bad json');

    blocTest<TranslateCubit, TranslateState>(
      'reports failures in the state',
      setUp: () => stubCheck(answer: () => Future.error(failure)),
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) => cubit.checkMeaning(),
      expect: () => [
        translated().copyWith(meaningStatus: ExtraStatus.loading),
        translated().copyWith(
          meaningStatus: ExtraStatus.failure,
          meaningError: () => failure,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'can be retried after a failure',
      setUp: stubCheck,
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        meaningStatus: ExtraStatus.failure,
        meaningError: () => failure,
      ),
      act: (cubit) => cubit.checkMeaning(),
      expect: () => [
        translated().copyWith(meaningStatus: ExtraStatus.loading),
        translated().copyWith(
          meaningStatus: ExtraStatus.ready,
          meaningCheck: () => check,
        ),
      ],
    );

    blocTest<TranslateCubit, TranslateState>(
      'is not requested again while loading or loaded',
      setUp: stubCheck,
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final first = cubit.checkMeaning();
        await cubit.checkMeaning();
        await first;
        await cubit.checkMeaning();
      },
      verify: (_) => verify(
        () => mocks.repository.checkMeaning(
          any(),
          source: any(named: 'source'),
          translation: any(named: 'translation'),
          sourceLanguage: any(named: 'sourceLanguage'),
          targetLanguage: any(named: 'targetLanguage'),
          uiLanguage: any(named: 'uiLanguage'),
        ),
      ).called(1),
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs a finished, current output',
      build: () => mocks.build(),
      act: (cubit) async {
        for (final state in [
          translated().copyWith(result: () => null),
          translated().copyWith(input: 'Hello'),
          translated().copyWith(status: TranslateStatus.translating),
          translated(result: resultOf('Hallo', isComplete: false)),
          translated(result: resultOf('  ')),
        ]) {
          cubit.emit(state);
          expect(cubit.state.canCheckMeaning, isFalse, reason: '$state');
          await cubit.checkMeaning();
        }
      },
      skip: 5,
      expect: () => <TranslateState>[],
      verify: (_) => verifyNoRequests(),
    );

    blocTest<TranslateCubit, TranslateState>(
      'is reset when the input changes, dropping a late answer',
      setUp: () => stubCheck(
        answer: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return check;
        },
      ),
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final done = cubit.checkMeaning();
        cubit.setInput('Hello there');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.meaningStatus, ExtraStatus.idle);
        expect(cubit.state.meaningCheck, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'drops a late failure after the result changed',
      setUp: () => stubCheck(
        answer: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          throw failure;
        },
      ),
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        final done = cubit.checkMeaning();
        cubit.useAlternative('Hallo, Welt');
        await done;
      },
      verify: (cubit) {
        expect(cubit.state.meaningStatus, ExtraStatus.idle);
        expect(cubit.state.meaningError, isNull);
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'is cleared by a new translation and never reloaded on its own',
      setUp: () {
        stubCheck();
        mocks.stubTranslate(hallo);
      },
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        meaningStatus: ExtraStatus.ready,
        meaningCheck: () => check,
        meaningFocus: () => 0,
      ),
      act: (cubit) => cubit.translate(),
      verify: (cubit) {
        expect(cubit.state.meaningStatus, ExtraStatus.idle);
        expect(cubit.state.meaningCheck, isNull);
        expect(cubit.state.meaningFocus, isNull);
        verifyNoRequests();
      },
    );
  });

  group('checkMeaning without an AI extras engine', () {
    /// "Hello world" -> "Hallo Welt" on a translation-only AI model.
    TranslateState onGemma({Language source = Language.auto}) => translated(
      engine: gemma,
      assistEngine: gemma,
      source: source,
      result: resultOf('Hallo Welt', engine: gemma, detected: 'en'),
    );

    blocTest<TranslateCubit, TranslateState>(
      'translates the output back into the detected source language',
      setUp: stubBackTranslate,
      build: () => mocks.build(),
      seed: onGemma,
      act: (cubit) => cubit.checkMeaning(uiLanguage: 'German'),
      expect: () => [
        onGemma().copyWith(meaningStatus: ExtraStatus.loading),
        onGemma().copyWith(
          meaningStatus: ExtraStatus.ready,
          backTranslation: () => 'Hello world',
        ),
      ],
      verify: (cubit) {
        expect(cubit.state.meaningUsesAi, isFalse);
        verify(
          () => mocks.repository.backTranslateResult(
            gemma,
            translation: 'Hallo Welt',
            from: de,
            to: en,
          ),
        ).called(1);
        verifyNever(
          () => mocks.repository.checkMeaning(
            any(),
            source: any(named: 'source'),
            translation: any(named: 'translation'),
            sourceLanguage: any(named: 'sourceLanguage'),
            targetLanguage: any(named: 'targetLanguage'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        );
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'uses the main engine when there is no AI engine at all',
      setUp: stubBackTranslate,
      build: () => mocks.build(),
      seed: () => translated(assistEngine: null, source: fr),
      act: (cubit) => cubit.checkMeaning(),
      verify: (_) => verify(
        () => mocks.repository.backTranslateResult(
          google,
          translation: 'Hallo Welt',
          from: de,
          to: fr,
        ),
      ).called(1),
    );

    blocTest<TranslateCubit, TranslateState>(
      'takes a detected language the engine does not list from the '
      'catalogue',
      setUp: stubBackTranslate,
      build: () => mocks.build(),
      seed: () => translated(
        assistEngine: null,
        result: resultOf('Hallo Welt', detected: 'ja'),
      ),
      act: (cubit) => cubit.checkMeaning(),
      verify: (_) {
        final to =
            verify(
                  () => mocks.repository.backTranslateResult(
                    any(),
                    translation: any(named: 'translation'),
                    from: any(named: 'from'),
                    to: captureAny(named: 'to'),
                  ),
                ).captured.single
                as Language;
        expect(to.code, 'ja');
        expect(to.name, 'Japanese');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'passes languages the engine does not list as they are',
      setUp: stubBackTranslate,
      build: () => mocks.build(),
      seed: () => translated(
        assistEngine: null,
        result: resultOf('Hallo Welt', detected: 'xx'),
      ).copyWith(sourceLanguages: const [Language.auto, en]),
      act: (cubit) => cubit.checkMeaning(),
      verify: (_) {
        final captured = verify(
          () => mocks.repository.backTranslateResult(
            any(),
            translation: any(named: 'translation'),
            from: captureAny(named: 'from'),
            to: captureAny(named: 'to'),
          ),
        ).captured;
        expect(captured.first, de);
        expect((captured.last as Language).code, 'xx');
      },
    );

    blocTest<TranslateCubit, TranslateState>(
      'needs a known source language',
      build: () => mocks.build(),
      seed: () =>
          translated(assistEngine: null, result: resultOf('Hallo Welt')),
      act: (cubit) {
        expect(cubit.state.canCheckMeaning, isFalse);
        return cubit.checkMeaning();
      },
      expect: () => <TranslateState>[],
      verify: (_) => verifyNoRequests(),
    );

    blocTest<TranslateCubit, TranslateState>(
      'counts a request, but not a cached back-translation',
      setUp: () {
        trackUsage();
        var calls = 0;
        stubBackTranslate(
          answer: () async => TranslationResult(
            engineId: gemma.id,
            engineName: gemma.name,
            text: 'Hello world',
            fromCache: calls++ > 0,
          ),
        );
      },
      build: () => mocks.build(),
      seed: onGemma,
      act: (cubit) async {
        await cubit.checkMeaning();
        cubit.clearMeaningCheck();
        await cubit.checkMeaning();
      },
      verify: (_) => verify(
        () => mocks.usageTracker!.recordText(
          'gemma',
          input: 'Hallo Welt',
          output: 'Hello world',
        ),
      ).called(1),
    );

    final failure = ArgumentError('custom language');

    blocTest<TranslateCubit, TranslateState>(
      'reports failures in the state',
      setUp: () => stubBackTranslate(answer: () => Future.error(failure)),
      build: () => mocks.build(),
      seed: onGemma,
      act: (cubit) => cubit.checkMeaning(),
      expect: () => [
        onGemma().copyWith(meaningStatus: ExtraStatus.loading),
        onGemma().copyWith(
          meaningStatus: ExtraStatus.failure,
          meaningError: () => failure,
        ),
      ],
    );
  });

  group('focusMeaningIssue', () {
    TranslateState checked() => translated().copyWith(
      meaningStatus: ExtraStatus.ready,
      meaningCheck: () => check,
    );

    blocTest<TranslateCubit, TranslateState>(
      'highlights an issue and clears the highlight',
      build: () => mocks.build(),
      seed: checked,
      act: (cubit) {
        cubit.focusMeaningIssue(0);
        expect(cubit.state.focusedMeaningIssue, issue);
        cubit
          ..focusMeaningIssue(0)
          ..focusMeaningIssue(null);
      },
      expect: () => [checked().copyWith(meaningFocus: () => 0), checked()],
    );

    blocTest<TranslateCubit, TranslateState>(
      'ignores indices out of range',
      build: () => mocks.build(),
      seed: checked,
      act: (cubit) => cubit
        ..focusMeaningIssue(2)
        ..focusMeaningIssue(-1),
      expect: () => <TranslateState>[],
      verify: (cubit) => expect(cubit.state.focusedMeaningIssue, isNull),
    );

    const spans = [
      AlignedSpan(sourceStart: 0, sourceEnd: 5, targetStart: 0, targetEnd: 5),
    ];

    blocTest<TranslateCubit, TranslateState>(
      'takes the place of the alignment highlight, and the other way round',
      build: () => mocks.build(),
      seed: () => checked().copyWith(
        alignmentStatus: ExtraStatus.ready,
        alignment: spans,
        alignmentFocus: () => 0,
      ),
      act: (cubit) {
        cubit.focusMeaningIssue(1);
        expect(cubit.state.alignmentFocus, isNull);
        cubit.focusAlignment(0);
        expect(cubit.state.meaningFocus, isNull);
        expect(cubit.state.alignmentFocus, 0);
      },
    );
  });

  group('clearMeaningCheck', () {
    blocTest<TranslateCubit, TranslateState>(
      'hides the check',
      build: () => mocks.build(),
      seed: () => translated().copyWith(
        meaningStatus: ExtraStatus.ready,
        meaningCheck: () => check,
        meaningFocus: () => 1,
      ),
      act: (cubit) => cubit
        ..clearMeaningCheck()
        ..clearMeaningCheck(),
      expect: () => [translated()],
    );

    blocTest<TranslateCubit, TranslateState>(
      'drops a check in flight',
      setUp: () {
        final answer = Completer<MeaningCheck>();
        stubCheck(answer: () => answer.future);
        addTearDown(() {
          if (!answer.isCompleted) answer.complete(check);
        });
      },
      build: () => mocks.build(),
      seed: translated,
      act: (cubit) async {
        unawaited(cubit.checkMeaning());
        await Future<void>.delayed(Duration.zero);
        cubit.clearMeaningCheck();
      },
      expect: () => [
        translated().copyWith(meaningStatus: ExtraStatus.loading),
        translated(),
      ],
    );
  });
}
