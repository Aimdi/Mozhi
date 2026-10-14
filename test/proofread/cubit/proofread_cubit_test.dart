import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

const _openAi = TranslationEngine(
  id: 'ai:openai',
  kind: EngineKind.ai,
  name: 'OpenAI',
  subtitle: 'gpt-4o',
);
const _ollama = TranslationEngine(
  id: 'ai:ollama',
  kind: EngineKind.ai,
  name: 'Ollama',
  isLocal: true,
);
const _google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
);

const _input = 'I has a apple and a orange.';
const _edits = [
  ProofreadEdit(original: 'has', replacement: 'have'),
  ProofreadEdit(original: 'a apple', replacement: 'an apple'),
  ProofreadEdit(original: 'a orange', replacement: 'an orange'),
];
const _result = ProofreadResult(
  correctedText: 'I have an apple and an orange.',
  edits: _edits,
  summary: 'Fixed agreement and articles.',
);

void main() {
  late TranslationRepository repository;

  setUpAll(() {
    registerFallbackValue(_openAi);
    registerFallbackValue(WritingStyle.general);
    registerFallbackValue(CorrectionLevel.standard);
    registerFallbackValue(Formality.automatic);
  });

  setUp(() {
    repository = _MockTranslationRepository();
  });

  void stubProofread(Future<ProofreadResult> Function() answer) {
    when(
      () => repository.proofread(
        any(),
        any(),
        style: any(named: 'style'),
        level: any(named: 'level'),
        formality: any(named: 'formality'),
        context: any(named: 'context'),
        uiLanguage: any(named: 'uiLanguage'),
      ),
    ).thenAnswer((_) => answer());
  }

  ProofreadCubit build({
    List<TranslationEngine> engines = const [_google, _openAi, _ollama],
    TranslationEngine? engine,
    String uiLanguage = 'English',
  }) => ProofreadCubit(
    repository: repository,
    engines: engines,
    engine: engine,
    uiLanguage: uiLanguage,
  );

  const ready = ProofreadState(
    input: _input,
    engine: _openAi,
    availableEngines: [_openAi, _ollama],
  );

  final success = ready.copyWith(
    status: ProofreadStatus.success,
    result: () => _result,
    proofreadInput: _input,
    acceptedEdits: {0, 1, 2},
  );

  group('ProofreadCubit', () {
    group('initial state', () {
      test('keeps only AI engines and selects the first by default', () {
        final cubit = build();
        expect(cubit.state.availableEngines, [_openAi, _ollama]);
        expect(cubit.state.engine, _openAi);
        expect(cubit.state.status, ProofreadStatus.idle);
      });

      test('selects the preferred engine when it is available', () {
        expect(build(engine: _ollama).state.engine, _ollama);
        expect(build(engine: _google).state.engine, _openAi);
      });

      test('has no engine when no AI engine exists', () {
        final cubit = build(engines: [_google]);
        expect(cubit.state.availableEngines, isEmpty);
        expect(cubit.state.engine, isNull);
      });
    });

    group('setEngines', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'keeps an engine the user picked while it is available',
        build: build,
        act: (cubit) => cubit
          ..setEngine(_ollama)
          ..setEngines([_openAi, _ollama], preferred: _openAi),
        expect: () => const [
          ProofreadState(engine: _ollama, availableEngines: [_openAi, _ollama]),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'follows the preferred engine until the user picks one',
        build: () => build(engine: _openAi),
        act: (cubit) => cubit
          ..setEngines([_openAi, _ollama], preferred: _ollama)
          ..setEngines([_openAi, _ollama]),
        expect: () => const [
          ProofreadState(engine: _ollama, availableEngines: [_openAi, _ollama]),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'follows the preferred engine again once the pick is removed',
        build: build,
        act: (cubit) => cubit
          ..setEngine(_ollama)
          ..setEngines([_openAi])
          ..setEngines([_openAi, _ollama], preferred: _ollama),
        expect: () => const [
          ProofreadState(engine: _ollama, availableEngines: [_openAi, _ollama]),
          ProofreadState(engine: _openAi, availableEngines: [_openAi]),
          ProofreadState(engine: _ollama, availableEngines: [_openAi, _ollama]),
        ],
      );

      test('refreshes details of an edited engine', () {
        const remote = TranslationEngine(
          id: 'ai:ollama',
          kind: EngineKind.ai,
          name: 'Ollama',
          subtitle: 'llama3.1',
        );
        final cubit = build(engine: _ollama)
          ..setEngines([_openAi, remote], preferred: remote);
        expect(cubit.state.engine?.subtitle, 'llama3.1');
        expect(cubit.state.engine?.isLocal, isFalse);
        expect(cubit.state.availableEngines.last.isLocal, isFalse);
      });

      blocTest<ProofreadCubit, ProofreadState>(
        'falls back to the preferred, then the first engine',
        build: () => build(engines: const []),
        act: (cubit) => cubit
          ..setEngines([_google, _openAi, _ollama], preferred: _ollama)
          ..setEngines([_openAi]),
        expect: () => const [
          ProofreadState(engine: _ollama, availableEngines: [_openAi, _ollama]),
          ProofreadState(engine: _openAi, availableEngines: [_openAi]),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'clears the engine when no AI engine remains',
        build: build,
        act: (cubit) => cubit.setEngines([_google]),
        expect: () => const [ProofreadState()],
      );
    });

    group('setEngine', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'selects an AI engine',
        build: build,
        act: (cubit) => cubit.setEngine(_ollama),
        expect: () => const [
          ProofreadState(engine: _ollama, availableEngines: [_openAi, _ollama]),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'ignores Mozhi engines',
        build: build,
        act: (cubit) => cubit.setEngine(_google),
        expect: () => <ProofreadState>[],
      );
    });

    group('setInput', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'updates the input once per change',
        build: build,
        act: (cubit) => cubit
          ..setInput('hello')
          ..setInput('hello'),
        expect: () => const [
          ProofreadState(
            input: 'hello',
            engine: _openAi,
            availableEngines: [_openAi, _ollama],
          ),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'resets a failure and clears the error',
        build: build,
        seed: () => ready.copyWith(
          status: ProofreadStatus.failure,
          error: () => 'boom',
        ),
        act: (cubit) => cubit.setInput('new'),
        expect: () => [ready.copyWith(input: 'new')],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'keeps the result while editing',
        build: build,
        seed: () => success,
        act: (cubit) => cubit.setInput('edited'),
        expect: () => [success.copyWith(input: 'edited')],
      );
    });

    group('options', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'update style, level, formality and context',
        build: build,
        act: (cubit) => cubit
          ..setStyle(WritingStyle.business)
          ..setLevel(CorrectionLevel.comprehensive)
          ..setFormality(Formality.less)
          ..setContext('email to my boss'),
        skip: 3,
        expect: () => const [
          ProofreadState(
            engine: _openAi,
            availableEngines: [_openAi, _ollama],
            writingStyle: WritingStyle.business,
            correctionLevel: CorrectionLevel.comprehensive,
            formality: Formality.less,
            context: 'email to my boss',
          ),
        ],
      );
    });

    group('proofread', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'emits loading then success with every edit accepted',
        setUp: () => stubProofread(() async => _result),
        build: () => build(uiLanguage: 'German'),
        seed: () => ready.copyWith(
          writingStyle: WritingStyle.academic,
          correctionLevel: CorrectionLevel.light,
          formality: Formality.more,
          context: '  thesis  ',
        ),
        act: (cubit) => cubit.proofread(),
        expect: () {
          final seeded = ready.copyWith(
            writingStyle: WritingStyle.academic,
            correctionLevel: CorrectionLevel.light,
            formality: Formality.more,
            context: '  thesis  ',
          );
          return [
            seeded.copyWith(status: ProofreadStatus.loading),
            seeded.copyWith(
              status: ProofreadStatus.success,
              result: () => _result,
              proofreadInput: _input,
              acceptedEdits: {0, 1, 2},
            ),
          ];
        },
        verify: (_) => verify(
          () => repository.proofread(
            _openAi,
            _input,
            style: WritingStyle.academic,
            level: CorrectionLevel.light,
            formality: Formality.more,
            context: 'thesis',
            uiLanguage: 'German',
          ),
        ).called(1),
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'keeps the previous result while re-proofreading',
        setUp: () => stubProofread(
          () async => const ProofreadResult(correctedText: _input),
        ),
        build: build,
        seed: () => success,
        act: (cubit) => cubit.proofread(),
        expect: () => [
          success.copyWith(status: ProofreadStatus.loading),
          success.copyWith(
            result: () => const ProofreadResult(correctedText: _input),
            acceptedEdits: {},
          ),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'turns changes missing from the edits into edits',
        setUp: () => stubProofread(
          () async => const ProofreadResult(
            correctedText: 'I have an apple and an orange. The end.',
            edits: _edits,
            summary: 'Fixed.',
          ),
        ),
        build: build,
        seed: () => ready.copyWith(input: '$_input Teh end.'),
        act: (cubit) => cubit.proofread(),
        expect: () => [
          ready.copyWith(
            input: '$_input Teh end.',
            status: ProofreadStatus.loading,
          ),
          ready.copyWith(
            input: '$_input Teh end.',
            status: ProofreadStatus.success,
            result: () => const ProofreadResult(
              correctedText: 'I have an apple and an orange. The end.',
              edits: [
                ..._edits,
                ProofreadEdit(
                  original: 'Teh',
                  replacement: 'The',
                  category: ProofreadDiff.otherCategory,
                ),
              ],
              summary: 'Fixed.',
            ),
            proofreadInput: '$_input Teh end.',
            acceptedEdits: {0, 1, 2, 3},
          ),
        ],
      );

      test('toggling one edit leaves every other change in place', () async {
        stubProofread(
          () async => const ProofreadResult(
            correctedText: 'I have an apple and an orange. The end.',
            edits: _edits,
          ),
        );
        final cubit = build()..setInput('$_input Teh end.');
        await cubit.proofread();
        cubit.toggleEdit(0);
        expect(cubit.outputText, 'I has an apple and an orange. The end.');
        await cubit.close();
      });

      test('applies the edits when the corrected text omits them', () async {
        stubProofread(
          () async =>
              const ProofreadResult(correctedText: _input, edits: _edits),
        );
        final cubit = build()..setInput(_input);
        await cubit.proofread();
        expect(cubit.state.edits, _edits);
        expect(cubit.outputText, 'I have an apple and an orange.');
        await cubit.close();
      });

      test('reconciles long texts in the background', () async {
        final words = List.generate(800, (i) => 'word$i');
        final input = words.join(' ');
        final corrected = [
          for (var i = 0; i < words.length; i++)
            if (i % 100 == 0) 'fixed$i' else words[i],
        ].join(' ');
        expect(
          input.length + corrected.length,
          greaterThanOrEqualTo(ProofreadCubit.backgroundDiffLength),
        );
        stubProofread(() async => ProofreadResult(correctedText: corrected));
        final cubit = build()..setInput(input);
        await cubit.proofread();
        expect(cubit.state.edits, hasLength(8));
        expect(cubit.outputText, corrected);
        await cubit.close();
      });

      blocTest<ProofreadCubit, ProofreadState>(
        'does nothing without input',
        build: build,
        seed: () => ready.copyWith(input: '   '),
        act: (cubit) => cubit.proofread(),
        expect: () => <ProofreadState>[],
        verify: (_) => verifyNever(
          () => repository.proofread(
            any(),
            any(),
            style: any(named: 'style'),
            level: any(named: 'level'),
            formality: any(named: 'formality'),
            context: any(named: 'context'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ),
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'does nothing without an engine',
        build: () => build(engines: const []),
        seed: () => const ProofreadState(input: 'text'),
        act: (cubit) => cubit.proofread(),
        expect: () => <ProofreadState>[],
      );

      const error = LlmApiException('bad key', statusCode: 401);
      blocTest<ProofreadCubit, ProofreadState>(
        'emits failure with the error',
        setUp: () => stubProofread(() async => throw error),
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.proofread(),
        expect: () => [
          ready.copyWith(status: ProofreadStatus.loading),
          ready.copyWith(status: ProofreadStatus.failure, error: () => error),
        ],
        errors: () => [error],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'clears a previous error when retrying',
        setUp: () => stubProofread(() async => _result),
        build: build,
        seed: () =>
            ready.copyWith(status: ProofreadStatus.failure, error: () => error),
        act: (cubit) => cubit.proofread(),
        expect: () => [
          ready.copyWith(status: ProofreadStatus.loading),
          success,
        ],
      );

      final completer = Completer<ProofreadResult>();
      blocTest<ProofreadCubit, ProofreadState>(
        'ignores a response that arrives after clear',
        setUp: () => stubProofread(() => completer.future),
        build: build,
        seed: () => ready,
        act: (cubit) async {
          final pending = cubit.proofread();
          cubit.clear();
          completer.complete(_result);
          await pending;
        },
        expect: () => [
          ready.copyWith(status: ProofreadStatus.loading),
          ready.copyWith(input: ''),
        ],
      );

      test('ignores a response that arrives after close', () async {
        final pending = Completer<ProofreadResult>();
        stubProofread(() => pending.future);
        final cubit = build()..setInput('text');
        final future = cubit.proofread();
        await cubit.close();
        pending.complete(_result);
        await expectLater(future, completes);
      });

      test('ignores an error that arrives after close', () async {
        final pending = Completer<ProofreadResult>();
        stubProofread(() => pending.future);
        final cubit = build()..setInput('text');
        final future = cubit.proofread();
        await cubit.close();
        pending.completeError(Exception('late'));
        await expectLater(future, completes);
      });
    });

    group('edits', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'toggleEdit rejects and re-accepts an edit',
        build: build,
        seed: () => success,
        act: (cubit) => cubit
          ..toggleEdit(1)
          ..toggleEdit(1),
        expect: () => [
          success.copyWith(acceptedEdits: {0, 2}),
          success.copyWith(acceptedEdits: {0, 1, 2}),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'toggleEdit ignores out-of-range indices',
        build: build,
        seed: () => success,
        act: (cubit) => cubit
          ..toggleEdit(-1)
          ..toggleEdit(3),
        expect: () => <ProofreadState>[],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'rejectAll and acceptAll',
        build: build,
        seed: () => success,
        act: (cubit) => cubit
          ..rejectAll()
          ..acceptAll(),
        expect: () => [
          success.copyWith(acceptedEdits: {}),
          success.copyWith(acceptedEdits: {0, 1, 2}),
        ],
      );

      test('outputText reflects accepted edits', () async {
        stubProofread(() async => _result);
        final cubit = build()..setInput(_input);
        await cubit.proofread();
        expect(cubit.outputText, 'I have an apple and an orange.');
        cubit.toggleEdit(0);
        expect(cubit.outputText, 'I has an apple and an orange.');
        cubit.rejectAll();
        expect(cubit.outputText, _input);
        await cubit.close();
      });
    });

    group('useOutputAsInput', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'moves the output into the input and clears the result',
        build: build,
        seed: () => success.copyWith(acceptedEdits: {1}),
        act: (cubit) => cubit.useOutputAsInput(),
        expect: () => [ready.copyWith(input: 'I has an apple and a orange.')],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'does nothing without a result',
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.useOutputAsInput(),
        expect: () => <ProofreadState>[],
      );
    });

    blocTest<ProofreadCubit, ProofreadState>(
      'clear resets input and result but keeps options',
      build: build,
      seed: () =>
          success.copyWith(writingStyle: WritingStyle.casual, context: 'chat'),
      act: (cubit) => cubit.clear(),
      expect: () => [
        ready.copyWith(
          input: '',
          writingStyle: WritingStyle.casual,
          context: 'chat',
        ),
      ],
    );

    group('usage', () {
      const billed = TranslationEngine(
        id: 'ai:p1',
        kind: EngineKind.ai,
        name: 'OpenAI',
        providerId: 'p1',
      );

      test('records a finished proofread for its provider', () async {
        stubProofread(() async => _result);
        final tracker = UsageTracker(store: MemoryStore());
        addTearDown(tracker.dispose);
        final cubit = ProofreadCubit(
          repository: repository,
          engines: const [billed],
          usageTracker: tracker,
        )..setInput(_input);
        addTearDown(cubit.close);

        await cubit.proofread();
        await pumpEventQueue();

        final stats = tracker.snapshot.statsFor('p1');
        expect(stats.requests, 1);
        expect(stats.inputChars, _input.length);
        expect(stats.outputChars, greaterThan(_result.correctedText.length));
      });

      test('does not record failures or engines without a provider', () async {
        final tracker = UsageTracker(store: MemoryStore());
        addTearDown(tracker.dispose);

        stubProofread(() async => throw Exception('offline'));
        final failing = ProofreadCubit(
          repository: repository,
          engines: const [billed],
          usageTracker: tracker,
        )..setInput(_input);
        addTearDown(failing.close);
        await failing.proofread();

        stubProofread(() async => _result);
        final unbilled = ProofreadCubit(
          repository: repository,
          engines: const [_openAi],
          usageTracker: tracker,
        )..setInput(_input);
        addTearDown(unbilled.close);
        await unbilled.proofread();
        await pumpEventQueue();

        expect(tracker.snapshot.hasUsage, isFalse);
      });
    });
  });
}
