import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/proofread/cubit/proofread_state.dart';
import 'package:mozhi/proofread/models/proofread_rephrasing.dart';
import 'package:mozhi/proofread/models/sentence_segmenter.dart';
import 'package:translation_repository/translation_repository.dart';

const _input = 'I has an apple. It is red.';
const _result = ProofreadResult(
  correctedText: 'I have an apple. It is red.',
  edits: [ProofreadEdit(original: 'has', replacement: 'have')],
);

void main() {
  const state = ProofreadState(
    status: ProofreadStatus.success,
    input: _input,
    proofreadInput: _input,
    result: _result,
    acceptedEdits: {0},
  );
  const crimson = ProofreadRephrasing(
    start: 17,
    end: 27,
    original: 'It is red.',
    replacement: 'It is crimson.',
  );

  group('ProofreadState rephrasing', () {
    test('defaults to the automatic tone and no rephrasings', () {
      const empty = ProofreadState();
      expect(empty.tone, WritingTone.automatic);
      expect(empty.rephrasings, isEmpty);
      expect(empty.alternatives, isNull);
      expect(empty.sentences, isEmpty);
      expect(empty.finalText, '');
    });

    test('splits the corrected text into sentences', () {
      expect(state.sentences, const [
        SentenceRange(0, 16),
        SentenceRange(17, 27),
      ]);
    });

    test('finalText applies the rephrasings to the corrected text', () {
      expect(state.finalText, 'I have an apple. It is red.');
      final rephrased = state.copyWith(rephrasings: const [crimson]);
      expect(rephrased.outputText, 'I have an apple. It is red.');
      expect(rephrased.finalText, 'I have an apple. It is crimson.');
    });

    test('rephrasingOf finds the rephrasing of a sentence', () {
      final rephrased = state.copyWith(rephrasings: const [crimson]);
      expect(rephrased.rephrasingOf(const SentenceRange(17, 27)), crimson);
      expect(rephrased.rephrasingOf(const SentenceRange(0, 16)), isNull);
    });

    test('copyWith sets and clears the new fields', () {
      const alternatives = ProofreadAlternatives(
        base: 'x',
        sentence: SentenceRange(0, 1),
        span: 'x',
      );
      final next = state.copyWith(
        tone: WritingTone.friendly,
        rephrasings: const [crimson],
        alternatives: () => alternatives,
      );
      expect(next.tone, WritingTone.friendly);
      expect(next.rephrasings, const [crimson]);
      expect(next.alternatives, alternatives);
      expect(next, isNot(state));
      expect(next.copyWith().alternatives, alternatives);
      expect(next.copyWith(alternatives: () => null).alternatives, isNull);
    });
  });

  group('ProofreadAlternatives', () {
    const loading = ProofreadAlternatives(
      base: 'Hi.',
      sentence: SentenceRange(0, 3),
      span: 'Hi.',
    );

    test('starts loading', () {
      expect(loading.isLoading, isTrue);
      expect(loading.alternatives, isEmpty);
      expect(loading.error, isNull);
    });

    test('copyWith keeps what it does not change', () {
      final error = Exception('x');
      final failed = loading.copyWith(
        status: ProofreadAlternativesStatus.failure,
        error: () => error,
      );
      expect(failed.isLoading, isFalse);
      expect(failed.error, error);
      expect(failed.base, 'Hi.');
      expect(failed.sentence, const SentenceRange(0, 3));
      expect(failed.span, 'Hi.');
      final done = failed.copyWith(
        status: ProofreadAlternativesStatus.success,
        alternatives: ['Hello.'],
        error: () => null,
      );
      expect(done.alternatives, ['Hello.']);
      expect(done.error, isNull);
      expect(done.copyWith(), done);
      expect(done, isNot(loading));
    });
  });
}
