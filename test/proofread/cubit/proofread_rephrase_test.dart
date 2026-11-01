import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/models/proofread_rephrasing.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

class _MockTranslationRepository extends Mock implements TranslationRepository;

const _openAi = TranslationEngine(
  id: 'ai:openai',
  kind: EngineKind.ai,
  name: 'OpenAI',
  subtitle: 'gpt-4o',
);

const _input = 'I has an apple. It is red. We likes it.';
const _edits = [
  ProofreadEdit(original: 'has', replacement: 'have'),
  ProofreadEdit(original: 'likes', replacement: 'like'),
];
const _result = ProofreadResult(
  correctedText: 'I have an apple. It is red. We like it.',
  edits: _edits,
);

// Sentences of the corrected text with both edits.
const _first = SentenceRange(0, 16);
const _second = SentenceRange(17, 27);
const _third = SentenceRange(28, 39);

void main() {
  late TranslationRepository repository;

  setUpAll(() {
    registerFallbackValue(_openAi);
    registerFallbackValue(WritingStyle.general);
    registerFallbackValue(CorrectionLevel.standard);
    registerFallbackValue(Formality.automatic);
    registerFallbackValue(ReadingLevel.standard);
    registerFallbackValue(ProofreadVariety.enGb);
    registerFallbackValue(WritingTone.automatic);
  });

  setUp(() => repository = _MockTranslationRepository());

  void stubProofread(Future<ProofreadResult> Function() answer) => when(
    () => repository.proofread(
      any(),
      any(),
      style: any(named: 'style'),
      level: any(named: 'level'),
      formality: any(named: 'formality'),
      readingLevel: any(named: 'readingLevel'),
      variety: any(named: 'variety'),
      context: any(named: 'context'),
      uiLanguage: any(named: 'uiLanguage'),
      tone: any(named: 'tone'),
    ),
  ).thenAnswer((_) => answer());

  void stubRephrase(Future<List<String>> Function() answer) => when(
    () => repository.rephrase(
      any(),
      any(),
      any(),
      style: any(named: 'style'),
      tone: any(named: 'tone'),
      formality: any(named: 'formality'),
      count: any(named: 'count'),
      uiLanguage: any(named: 'uiLanguage'),
    ),
  ).thenAnswer((_) => answer());

  ProofreadCubit build({UsageTracker? usageTracker}) => ProofreadCubit(
    repository: repository,
    engines: const [_openAi],
    uiLanguage: 'German',
    usageTracker: usageTracker,
  );

  const ready = ProofreadState(
    input: _input,
    engine: _openAi,
    availableEngines: [_openAi],
  );

  final success = ready.copyWith(
    status: ProofreadStatus.success,
    result: () => _result,
    proofreadInput: _input,
    acceptedEdits: {0, 1},
  );

  ProofreadRephrasing rephrasing(SentenceRange range, String replacement) =>
      ProofreadRephrasing(
        start: range.start,
        end: range.end,
        original: range.of(_result.correctedText),
        replacement: replacement,
      );

  group('ProofreadCubit tone', () {
    blocTest<ProofreadCubit, ProofreadState>(
      'setTone updates the tone',
      build: build,
      act: (cubit) => cubit
        ..setTone(WritingTone.friendly)
        ..setTone(WritingTone.automatic),
      expect: () => const [
        ProofreadState(
          engine: _openAi,
          availableEngines: [_openAi],
          tone: WritingTone.friendly,
        ),
        ProofreadState(engine: _openAi, availableEngines: [_openAi]),
      ],
    );

    blocTest<ProofreadCubit, ProofreadState>(
      'proofread sends the tone',
      setUp: () => stubProofread(() async => _result),
      build: build,
      seed: () => ready.copyWith(tone: WritingTone.confident),
      act: (cubit) => cubit.proofread(),
      verify: (_) => verify(
        () => repository.proofread(
          _openAi,
          _input,
          uiLanguage: 'German',
          tone: WritingTone.confident,
        ),
      ).called(1),
    );
  });

  group('ProofreadCubit rephrasing', () {
    group('loadAlternatives', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'emits loading then the alternatives',
        setUp: () => stubRephrase(() async => ['It is crimson.']),
        build: build,
        seed: () => success.copyWith(
          writingStyle: WritingStyle.business,
          tone: WritingTone.diplomatic,
          formality: Formality.more,
        ),
        act: (cubit) => cubit.loadAlternatives(_second),
        expect: () {
          final seeded = success.copyWith(
            writingStyle: WritingStyle.business,
            tone: WritingTone.diplomatic,
            formality: Formality.more,
          );
          const loading = ProofreadAlternatives(
            base: 'I have an apple. It is red. We like it.',
            sentence: _second,
            span: 'It is red.',
          );
          return [
            seeded.copyWith(alternatives: () => loading),
            seeded.copyWith(
              alternatives: () => loading.copyWith(
                status: ProofreadAlternativesStatus.success,
                alternatives: ['It is crimson.'],
              ),
            ),
          ];
        },
        verify: (_) => verify(
          () => repository.rephrase(
            _openAi,
            'I have an apple. It is red. We like it.',
            'It is red.',
            style: WritingStyle.business,
            tone: WritingTone.diplomatic,
            formality: Formality.more,
            uiLanguage: 'German',
          ),
        ).called(1),
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'asks for the rephrased sentence with the final text as context',
        setUp: () => stubRephrase(() async => const []),
        build: build,
        seed: () => success.copyWith(
          rephrasings: [rephrasing(_second, 'It is crimson.')],
        ),
        act: (cubit) => cubit.loadAlternatives(_second),
        skip: 1,
        expect: () => [
          success.copyWith(
            rephrasings: [rephrasing(_second, 'It is crimson.')],
            alternatives: () => const ProofreadAlternatives(
              base: 'I have an apple. It is red. We like it.',
              sentence: _second,
              span: 'It is crimson.',
              status: ProofreadAlternativesStatus.success,
            ),
          ),
        ],
        verify: (_) => verify(
          () => repository.rephrase(
            _openAi,
            'I have an apple. It is crimson. We like it.',
            'It is crimson.',
            uiLanguage: 'German',
          ),
        ).called(1),
      );

      final failure = Exception('down');
      blocTest<ProofreadCubit, ProofreadState>(
        'emits a failure',
        setUp: () => stubRephrase(() async => throw failure),
        build: build,
        seed: () => success,
        act: (cubit) => cubit.loadAlternatives(_first),
        skip: 1,
        expect: () => [
          success.copyWith(
            alternatives: () => ProofreadAlternatives(
              base: 'I have an apple. It is red. We like it.',
              sentence: _first,
              span: 'I have an apple.',
              status: ProofreadAlternativesStatus.failure,
              error: failure,
            ),
          ),
        ],
        errors: () => [failure],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'does nothing for a range that is no sentence, or without a result',
        build: build,
        seed: () => success,
        act: (cubit) async {
          await cubit.loadAlternatives(const SentenceRange(0, 3));
          cubit
            ..rejectAll()
            ..clear();
          await cubit.loadAlternatives(_first);
        },
        skip: 2,
        expect: () => const <ProofreadState>[],
        verify: (_) => verifyNever(
          () => repository.rephrase(
            any(),
            any(),
            any(),
            style: any(named: 'style'),
            tone: any(named: 'tone'),
            formality: any(named: 'formality'),
            count: any(named: 'count'),
            uiLanguage: any(named: 'uiLanguage'),
          ),
        ),
      );

      test('ignores alternatives that arrive after closing them', () async {
        final response = Completer<List<String>>();
        stubRephrase(() => response.future);
        final cubit = build()..emit(success);
        addTearDown(cubit.close);
        unawaited(cubit.loadAlternatives(_first));
        expect(cubit.state.alternatives?.isLoading, isTrue);
        cubit
          ..closeAlternatives(_second)
          ..closeAlternatives(_first);
        expect(cubit.state.alternatives, isNull);
        response.complete(['I own an apple.']);
        await pumpEventQueue();
        expect(cubit.state.alternatives, isNull);
      });

      test('ignores an error that arrives after a new result', () async {
        final response = Completer<List<String>>();
        stubRephrase(() => response.future);
        stubProofread(() async => _result);
        final cubit = build()..emit(success);
        addTearDown(cubit.close);
        unawaited(cubit.loadAlternatives(_first));
        await cubit.proofread();
        expect(cubit.state.alternatives, isNull);
        response.completeError(Exception('late'));
        await pumpEventQueue();
        expect(cubit.state.alternatives, isNull);
      });

      test('ignores a response after close', () async {
        final response = Completer<List<String>>();
        stubRephrase(() => response.future);
        final cubit = build()..emit(success);
        unawaited(cubit.loadAlternatives(_first));
        await cubit.close();
        response.complete(['x']);
        await pumpEventQueue();
        expect(cubit.state.alternatives?.isLoading, isTrue);
        // Closing the sheet after the page closed does nothing.
        cubit.closeAlternatives(_first);
      });

      test('records the request for its provider', () async {
        const billed = TranslationEngine(
          id: 'ai:p1',
          kind: EngineKind.ai,
          name: 'OpenAI',
          providerId: 'p1',
        );
        stubRephrase(() async => ['I own an apple.']);
        final tracker = UsageTracker(store: MemoryStore());
        addTearDown(tracker.dispose);
        final cubit = build(usageTracker: tracker)
          ..emit(success.copyWith(engine: () => billed));
        addTearDown(cubit.close);
        await cubit.loadAlternatives(_first);
        await pumpEventQueue();
        final stats = tracker.snapshot.statsFor('p1');
        expect(stats.requests, 1);
        expect(stats.outputChars, 'I own an apple.'.length);
      });
    });

    blocTest<ProofreadCubit, ProofreadState>(
      'rephrases a sentence of a clean result',
      setUp: () => stubRephrase(() async => ['We love it.']),
      build: build,
      seed: () => ready.copyWith(
        input: 'Fine. We like it.',
        status: ProofreadStatus.success,
        result: () => const ProofreadResult(correctedText: 'Fine. We like it.'),
        proofreadInput: 'Fine. We like it.',
      ),
      act: (cubit) async {
        await cubit.loadAlternatives(const SentenceRange(6, 17));
        cubit.rephraseSentence(const SentenceRange(6, 17), 'We love it.');
      },
      verify: (cubit) {
        expect(cubit.state.isClean, isTrue);
        expect(cubit.state.finalText, 'Fine. We love it.');
        verify(
          () => repository.rephrase(
            _openAi,
            'Fine. We like it.',
            'We like it.',
            uiLanguage: 'German',
          ),
        ).called(1);
      },
    );

    group('rephraseSentence', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'replaces the sentence in the final text and closes its alternatives',
        build: build,
        seed: () => success.copyWith(
          alternatives: () => const ProofreadAlternatives(
            base: 'I have an apple. It is red. We like it.',
            sentence: _second,
            span: 'It is red.',
          ),
        ),
        act: (cubit) => cubit.rephraseSentence(_second, 'It is crimson.'),
        expect: () => [
          success.copyWith(
            rephrasings: [rephrasing(_second, 'It is crimson.')],
          ),
        ],
        verify: (cubit) {
          expect(
            cubit.state.finalText,
            'I have an apple. It is crimson. We like it.',
          );
          expect(cubit.state.outputText, _result.correctedText);
        },
      );

      blocTest<ProofreadCubit, ProofreadState>(
        "keeps another sentence's alternatives open",
        build: build,
        seed: () => success.copyWith(
          alternatives: () => const ProofreadAlternatives(
            base: 'I have an apple. It is red. We like it.',
            sentence: _first,
            span: 'I have an apple.',
          ),
        ),
        act: (cubit) => cubit.rephraseSentence(_third, 'We love it.'),
        verify: (cubit) {
          expect(cubit.state.alternatives?.sentence, _first);
          expect(cubit.state.rephrasings, [rephrasing(_third, 'We love it.')]);
        },
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'restoreSentence puts the sentence back',
        build: build,
        seed: () => success.copyWith(
          rephrasings: [
            rephrasing(_first, 'I own an apple.'),
            rephrasing(_second, 'It is crimson.'),
          ],
        ),
        act: (cubit) => cubit.restoreSentence(_second),
        expect: () => [
          success.copyWith(
            rephrasings: [rephrasing(_first, 'I own an apple.')],
          ),
        ],
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'does nothing without a result',
        build: build,
        seed: () => ready,
        act: (cubit) => cubit.rephraseSentence(_first, 'x'),
        expect: () => const <ProofreadState>[],
      );
    });

    group('with the edits', () {
      blocTest<ProofreadCubit, ProofreadState>(
        'toggling an edit keeps the rephrasings it does not touch',
        build: build,
        seed: () => success.copyWith(
          rephrasings: [
            rephrasing(_second, 'It is crimson.'),
            rephrasing(_third, 'We love it.'),
          ],
          alternatives: () => const ProofreadAlternatives(
            base: 'I have an apple. It is red. We like it.',
            sentence: _second,
            span: 'It is red.',
          ),
        ),
        // Rejecting "has -> have" makes the text one character shorter
        // before both rephrased sentences.
        act: (cubit) => cubit.toggleEdit(0),
        verify: (cubit) {
          final state = cubit.state;
          expect(state.outputText, 'I has an apple. It is red. We like it.');
          expect(state.alternatives, isNull);
          expect(state.finalText, 'I has an apple. It is crimson. We love it.');
        },
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'drops the rephrasing of a sentence an edit changes',
        build: build,
        seed: () => success.copyWith(
          rephrasings: [
            rephrasing(_first, 'I own an apple.'),
            rephrasing(_third, 'We love it.'),
          ],
        ),
        act: (cubit) => cubit.rejectAll(),
        verify: (cubit) {
          expect(cubit.state.rephrasings, isEmpty);
          expect(cubit.state.finalText, _input);
        },
      );

      blocTest<ProofreadCubit, ProofreadState>(
        'accepting edits that are already applied keeps everything',
        build: build,
        seed: () => success.copyWith(
          rephrasings: [rephrasing(_first, 'I own an apple.')],
        ),
        act: (cubit) => cubit.acceptAll(),
        expect: () => const <ProofreadState>[],
      );
    });

    blocTest<ProofreadCubit, ProofreadState>(
      'a new result drops the rephrasings',
      setUp: () => stubProofread(() async => _result),
      build: build,
      seed: () => success.copyWith(
        rephrasings: [rephrasing(_first, 'I own an apple.')],
      ),
      act: (cubit) => cubit.proofread(),
      verify: (cubit) => expect(cubit.state.rephrasings, isEmpty),
    );

    blocTest<ProofreadCubit, ProofreadState>(
      'useOutputAsInput keeps the rephrasings in the text',
      build: build,
      seed: () => success.copyWith(
        rephrasings: [rephrasing(_first, 'I own an apple.')],
      ),
      act: (cubit) => cubit.useOutputAsInput(),
      verify: (cubit) {
        expect(cubit.state.input, 'I own an apple. It is red. We like it.');
        expect(cubit.state.result, isNull);
        expect(cubit.state.rephrasings, isEmpty);
      },
    );

    blocTest<ProofreadCubit, ProofreadState>(
      'clear drops the rephrasings and alternatives',
      build: build,
      seed: () => success.copyWith(
        rephrasings: [rephrasing(_first, 'I own an apple.')],
        alternatives: () => const ProofreadAlternatives(
          base: 'I have an apple. It is red. We like it.',
          sentence: _first,
          span: 'I own an apple.',
        ),
      ),
      act: (cubit) => cubit.clear(),
      verify: (cubit) {
        expect(cubit.state.rephrasings, isEmpty);
        expect(cubit.state.alternatives, isNull);
      },
    );
  });
}
