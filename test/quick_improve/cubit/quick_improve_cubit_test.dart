import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/quick_improve/quick_improve.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _ready = ImproveEngines(engines: [claude, ollama]);
const _loading = ImproveEngines(status: ImproveEnginesStatus.loading);

void main() {
  setUpAll(registerQuickImproveFallbacks);

  late MockTranslationRepository repository;

  setUp(() {
    repository = MockTranslationRepository();
    stubProofread(repository);
  });

  QuickImproveCubit build({
    ImproveEngines engines = _ready,
    String text = sentence,
    UsageTracker? usageTracker,
    String uiLanguage = 'English',
  }) => QuickImproveCubit(
    repository: repository,
    text: text,
    engines: engines,
    usageTracker: usageTracker,
    uiLanguage: uiLanguage,
  );

  TypeMatcher<QuickImproveState> improving({
    TranslationEngine engine = claude,
  }) => isA<QuickImproveState>()
      .having((s) => s.status, 'status', QuickImproveStatus.improving)
      .having((s) => s.engine, 'engine', engine)
      .having((s) => s.result, 'result', isNull);

  TypeMatcher<QuickImproveState> improved(
    String text, {
    TranslationEngine engine = claude,
  }) => isA<QuickImproveState>()
      .having((s) => s.status, 'status', QuickImproveStatus.success)
      .having((s) => s.engine, 'engine', engine)
      .having((s) => s.improvedText, 'improvedText', text);

  void verifyProofread({
    TranslationEngine engine = claude,
    String text = sentence,
    WritingStyle style = WritingStyle.general,
    CorrectionLevel level = CorrectionLevel.standard,
    String uiLanguage = 'English',
    int times = 1,
  }) => verify(
    () => repository.proofread(
      engine,
      text,
      style: style,
      level: level,
      uiLanguage: uiLanguage,
    ),
  ).called(times);

  group('QuickImproveCubit', () {
    test("starts with the Proofread tab's engine, waiting", () {
      final cubit = build(
        engines: const ImproveEngines(
          engines: [claude, ollama],
          preferred: ollama,
        ),
      );
      addTearDown(cubit.close);
      expect(cubit.state.engine, ollama);
      expect(cubit.state.engines, [claude, ollama]);
      expect(cubit.state.status, QuickImproveStatus.loadingEngines);
      expect(cubit.state.text, sentence);
    });

    group('start', () {
      blocTest<QuickImproveCubit, QuickImproveState>(
        'proofreads right away and applies every edit',
        build: () => build(uiLanguage: 'German'),
        act: (cubit) => cubit.start(),
        expect: () => [
          improving(),
          improved('I have a cat.')
              .having((s) => s.result, 'result', fixed)
              .having((s) => s.segments, 'segments', [
                const DiffSegment.unchanged('I '),
                const DiffSegment.removed('has', editIndex: 0),
                const DiffSegment.inserted('have', editIndex: 0),
                const DiffSegment.unchanged(' a cat.'),
              ]),
        ],
        verify: (_) => verifyProofread(uiLanguage: 'German'),
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'waits for the engines while they load',
        build: () => build(engines: _loading),
        act: (cubit) => cubit.start(),
        expect: () => const <QuickImproveState>[],
        verify: (_) => verifyNever(
          () => repository.proofread(
            any(),
            any(),
            style: any(named: 'style'),
            level: any(named: 'level'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ),
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'says when no AI engine can proofread',
        build: () => build(engines: const ImproveEngines()),
        act: (cubit) => cubit.start(),
        expect: () => [
          isA<QuickImproveState>()
              .having((s) => s.status, 'status', QuickImproveStatus.noEngine)
              .having((s) => s.engine, 'engine', isNull),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'says when the engines failed to load',
        build: () => build(
          engines: const ImproveEngines(status: ImproveEnginesStatus.failure),
        ),
        act: (cubit) => cubit.start(),
        expect: () => [
          isA<QuickImproveState>().having(
            (s) => s.status,
            'status',
            QuickImproveStatus.enginesFailed,
          ),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'uses known engines even when the list failed to refresh',
        build: () => build(
          engines: const ImproveEngines(
            engines: [claude],
            status: ImproveEnginesStatus.failure,
          ),
        ),
        act: (cubit) => cubit.start(),
        expect: () => [improving(), improved('I have a cat.')],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'does nothing for blank text',
        build: () => build(text: '   '),
        act: (cubit) => cubit.start(),
        expect: () => const <QuickImproveState>[],
      );
    });

    group('updateEngines', () {
      blocTest<QuickImproveCubit, QuickImproveState>(
        'proofreads once the first engine is known',
        build: () => build(engines: _loading),
        act: (cubit) async {
          await cubit.start();
          await cubit.updateEngines(_loading);
          await cubit.updateEngines(_ready);
        },
        expect: () => [
          isA<QuickImproveState>()
              .having(
                (s) => s.status,
                'status',
                QuickImproveStatus.loadingEngines,
              )
              .having((s) => s.engine, 'engine', claude),
          improving(),
          improved('I have a cat.'),
        ],
        verify: (_) => verifyProofread(),
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'recovers from a failed engine list',
        build: () => build(
          engines: const ImproveEngines(status: ImproveEnginesStatus.failure),
        ),
        act: (cubit) async {
          await cubit.start();
          await cubit.updateEngines(_loading);
          await cubit.updateEngines(_ready);
        },
        expect: () => [
          isA<QuickImproveState>().having(
            (s) => s.status,
            'status',
            QuickImproveStatus.enginesFailed,
          ),
          isA<QuickImproveState>().having(
            (s) => s.status,
            'status',
            QuickImproveStatus.loadingEngines,
          ),
          isA<QuickImproveState>()
              .having(
                (s) => s.status,
                'status',
                QuickImproveStatus.loadingEngines,
              )
              .having((s) => s.engine, 'engine', claude),
          improving(),
          improved('I have a cat.'),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'says when the loaded list has no AI engine',
        build: () => build(engines: _loading),
        act: (cubit) async {
          await cubit.start();
          await cubit.updateEngines(const ImproveEngines());
        },
        expect: () => [
          isA<QuickImproveState>().having(
            (s) => s.status,
            'status',
            QuickImproveStatus.noEngine,
          ),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'does not proofread before start',
        build: () => build(engines: _loading),
        act: (cubit) => cubit.updateEngines(_ready),
        expect: () => [
          isA<QuickImproveState>()
              .having(
                (s) => s.status,
                'status',
                QuickImproveStatus.loadingEngines,
              )
              .having((s) => s.engine, 'engine', claude),
        ],
        verify: (_) => verifyNever(
          () => repository.proofread(
            any(),
            any(),
            style: any(named: 'style'),
            level: any(named: 'level'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ),
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'keeps the result and follows the assist engine afterwards',
        build: build,
        act: (cubit) async {
          await cubit.start();
          await cubit.updateEngines(
            const ImproveEngines(engines: [claude, ollama], preferred: ollama),
          );
        },
        skip: 2,
        expect: () => [improved('I have a cat.', engine: ollama)],
        verify: (_) => verifyProofread(),
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'keeps an engine the user picked while it is available',
        build: build,
        act: (cubit) async {
          await cubit.start();
          await cubit.selectEngine(ollama);
          await cubit.updateEngines(
            const ImproveEngines(engines: [claude, ollama], preferred: claude),
          );
          await cubit.updateEngines(const ImproveEngines(engines: [claude]));
        },
        skip: 5,
        expect: () => [improved('I have a cat.')],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'does nothing once closed',
        build: build,
        act: (cubit) async {
          await cubit.close();
          await cubit.updateEngines(const ImproveEngines());
        },
        expect: () => const <QuickImproveState>[],
      );
    });

    group('errors', () {
      blocTest<QuickImproveCubit, QuickImproveState>(
        'reports a failed proofread; retry proofreads again',
        setUp: () => stubProofread(
          repository,
          error: const LlmApiException('Overloaded', statusCode: 529),
        ),
        build: build,
        act: (cubit) async {
          await cubit.start();
          stubProofread(repository);
          await cubit.retry();
        },
        expect: () => [
          improving(),
          isA<QuickImproveState>()
              .having((s) => s.status, 'status', QuickImproveStatus.failure)
              .having((s) => s.error, 'error', isA<LlmApiException>()),
          improving(),
          improved('I have a cat.'),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'stops for consent: nothing was sent',
        setUp: () => stubProofread(repository, error: consent),
        build: build,
        act: (cubit) => cubit.start(),
        expect: () => [
          improving(),
          isA<QuickImproveState>()
              .having((s) => s.status, 'status', QuickImproveStatus.failure)
              .having((s) => s.error, 'error', consent),
        ],
      );
    });

    group('options', () {
      blocTest<QuickImproveCubit, QuickImproveState>(
        'a correction level proofreads again',
        build: build,
        act: (cubit) async {
          await cubit.start();
          await cubit.setLevel(CorrectionLevel.standard);
          await cubit.setLevel(CorrectionLevel.comprehensive);
        },
        skip: 2,
        expect: () => [
          isA<QuickImproveState>().having(
            (s) => s.level,
            'level',
            CorrectionLevel.comprehensive,
          ),
          improving(),
          improved('I have a cat.'),
        ],
        verify: (_) {
          verifyProofread();
          verifyProofread(level: CorrectionLevel.comprehensive);
        },
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'a style proofreads again',
        build: build,
        act: (cubit) async {
          await cubit.start();
          await cubit.setStyle(WritingStyle.general);
          await cubit.setStyle(WritingStyle.email);
        },
        skip: 2,
        expect: () => [
          isA<QuickImproveState>().having(
            (s) => s.style,
            'style',
            WritingStyle.email,
          ),
          improving(),
          improved('I have a cat.'),
        ],
        verify: (_) => verifyProofread(style: WritingStyle.email),
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'options picked before the first proofread only change the state',
        build: () => build(engines: _loading),
        act: (cubit) async {
          await cubit.setLevel(CorrectionLevel.light);
          await cubit.setStyle(WritingStyle.casual);
        },
        expect: () => [
          isA<QuickImproveState>().having(
            (s) => s.level,
            'level',
            CorrectionLevel.light,
          ),
          isA<QuickImproveState>().having(
            (s) => s.style,
            'style',
            WritingStyle.casual,
          ),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'another engine proofreads with it',
        build: build,
        act: (cubit) async {
          await cubit.start();
          await cubit.selectEngine(claude);
          await cubit.selectEngine(hyMt);
          await cubit.selectEngine(ollama);
        },
        skip: 2,
        expect: () => [
          isA<QuickImproveState>()
              .having((s) => s.engine, 'engine', ollama)
              .having((s) => s.status, 'status', QuickImproveStatus.success),
          improving(engine: ollama),
          improved('I have a cat.', engine: ollama),
        ],
        verify: (_) {
          verifyProofread();
          verifyProofread(engine: ollama);
        },
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'the same engine retries after a failure',
        setUp: () => stubProofread(repository, error: Exception('boom')),
        build: build,
        act: (cubit) async {
          await cubit.start();
          await cubit.selectEngine(claude);
        },
        verify: (_) => verifyProofread(times: 2),
      );
    });

    group('results', () {
      blocTest<QuickImproveCubit, QuickImproveState>(
        'uses the corrected text of a result without edits',
        setUp: () => stubProofread(
          repository,
          answer: const ProofreadResult(correctedText: 'I have a cat.'),
        ),
        build: build,
        act: (cubit) => cubit.start(),
        skip: 1,
        expect: () => [
          improved('I have a cat.')
              .having((s) => s.isUnchanged, 'isUnchanged', isFalse)
              .having(
                (s) => s.segments.where((s) => s.type != DiffType.unchanged),
                'changes',
                isNotEmpty,
              )
              // The unlisted change became an edit.
              .having((s) => s.result?.edits, 'edits', hasLength(1)),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'adds unlisted changes of the corrected text',
        setUp: () => stubProofread(
          repository,
          answer: const ProofreadResult(
            correctedText: 'I have a dog.',
            edits: [ProofreadEdit(original: 'has', replacement: 'have')],
            maskedPersonalData: 2,
          ),
        ),
        build: build,
        act: (cubit) => cubit.start(),
        skip: 1,
        expect: () => [
          improved('I have a dog.')
              .having((s) => s.result?.edits, 'edits', hasLength(2))
              .having((s) => s.maskedPersonalData, 'masked', 2),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'finds nothing to improve',
        setUp: () => stubProofread(
          repository,
          answer: const ProofreadResult(correctedText: sentence),
        ),
        build: build,
        act: (cubit) => cubit.start(),
        skip: 1,
        expect: () => [
          improved(sentence)
              .having((s) => s.isUnchanged, 'isUnchanged', isTrue),
        ],
      );

      blocTest<QuickImproveCubit, QuickImproveState>(
        'keeps the text for a blank answer',
        setUp: () => stubProofread(
          repository,
          answer: const ProofreadResult(correctedText: '  '),
        ),
        build: build,
        act: (cubit) => cubit.start(),
        skip: 1,
        expect: () => [
          improved(sentence)
              .having((s) => s.isUnchanged, 'isUnchanged', isTrue),
        ],
      );

      test('compares long texts in the background', () async {
        final long = List.filled(700, 'I has a cat.').join(' ');
        expect(
          long.length * 2,
          greaterThanOrEqualTo(QuickImproveCubit.backgroundDiffLength),
        );
        stubProofread(
          repository,
          answer: ProofreadResult(
            correctedText: long.replaceFirst('has', 'have'),
            edits: const [ProofreadEdit(original: 'has', replacement: 'have')],
          ),
        );
        final cubit = build(text: long);
        addTearDown(cubit.close);

        await cubit.start();

        expect(cubit.state.status, QuickImproveStatus.success);
        expect(cubit.state.improvedText, long.replaceFirst('has', 'have'));
      });

      test('ignores a stale result', () async {
        final first = Completer<ProofreadResult>();
        when(
          () => repository.proofread(
            any(),
            any(),
            style: any(named: 'style'),
            level: any(named: 'level', that: equals(CorrectionLevel.standard)),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ).thenAnswer((_) => first.future);
        when(
          () => repository.proofread(
            any(),
            any(),
            style: any(named: 'style'),
            level: CorrectionLevel.light,
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ).thenAnswer(
          (_) async => const ProofreadResult(correctedText: 'I have cats.'),
        );
        final cubit = build();
        addTearDown(cubit.close);

        unawaited(cubit.start());
        await cubit.setLevel(CorrectionLevel.light);
        first.complete(fixed);
        await pumpEventQueue();

        expect(cubit.state.improvedText, 'I have cats.');
        expect(cubit.state.level, CorrectionLevel.light);
      });

      test('emits nothing once closed while proofreading', () async {
        final pending = Completer<ProofreadResult>();
        when(
          () => repository.proofread(
            any(),
            any(),
            style: any(named: 'style'),
            level: any(named: 'level'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ).thenAnswer((_) => pending.future);
        final cubit = build();
        final done = cubit.start();
        await cubit.close();
        pending.complete(fixed);
        await expectLater(done, completes);
      });

      test('an error after closing is ignored', () async {
        final pending = Completer<ProofreadResult>();
        when(
          () => repository.proofread(
            any(),
            any(),
            style: any(named: 'style'),
            level: any(named: 'level'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ).thenAnswer((_) => pending.future);
        final cubit = build();
        final done = cubit.start();
        await cubit.close();
        pending.completeError(Exception('late'));
        await expectLater(done, completes);
      });
    });

    group('usage', () {
      late MockUsageTracker tracker;

      setUp(() {
        tracker = MockUsageTracker();
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => UsageStats.zero);
      });

      test("counts what a provider's proofread sent and received", () async {
        final cubit = build(usageTracker: tracker);
        addTearDown(cubit.close);

        await cubit.start();

        verify(
          () => tracker.recordText(
            'claude',
            input: sentence,
            output: 'I have a cat.\nOne grammar fix.\nSubject-verb agreement',
          ),
        ).called(1);
      });

      test('counts nothing for an engine without a provider', () async {
        const local = TranslationEngine(
          id: 'ai:local',
          kind: EngineKind.ai,
          name: 'Local',
        );
        final cubit = build(
          usageTracker: tracker,
          engines: const ImproveEngines(engines: [local]),
        );
        addTearDown(cubit.close);

        await cubit.start();

        expect(cubit.state.status, QuickImproveStatus.success);
        verifyNever(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        );
      });

      test('a failing tracker never breaks the proofread', () async {
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenThrow(StateError('closed'));
        final cubit = build(usageTracker: tracker);
        addTearDown(cubit.close);

        await cubit.start();

        expect(cubit.state.status, QuickImproveStatus.success);
      });

      test('a failing count never breaks the proofread', () async {
        when(
          () => tracker.recordText(
            any(),
            input: any(named: 'input'),
            output: any(named: 'output'),
          ),
        ).thenAnswer((_) async => throw StateError('disk full'));
        final cubit = build(usageTracker: tracker);
        addTearDown(cubit.close);

        await cubit.start();
        await pumpEventQueue();

        expect(cubit.state.status, QuickImproveStatus.success);
      });
    });
  });
}
