import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

const _engine = TranslationEngine(
  id: 'ai:openai',
  kind: EngineKind.ai,
  name: 'OpenAI',
);

ProofreadEdit _edit(String original, String replacement) =>
    ProofreadEdit(original: original, replacement: replacement);

ProofreadState _state(
  String input,
  List<ProofreadEdit> edits, {
  Set<int>? accepted,
  String corrected = '',
  String summary = '',
}) => ProofreadState(
  input: input,
  proofreadInput: input,
  status: ProofreadStatus.success,
  result: ProofreadResult(
    correctedText: corrected,
    edits: edits,
    summary: summary,
  ),
  acceptedEdits: accepted ?? {for (var i = 0; i < edits.length; i++) i},
);

void main() {
  group('ProofreadState', () {
    test('supports value equality', () {
      expect(const ProofreadState(), const ProofreadState());
      expect(
        const ProofreadState(acceptedEdits: {1, 2}),
        const ProofreadState(acceptedEdits: {2, 1}),
      );
      expect(
        const ProofreadState(input: 'a'),
        isNot(const ProofreadState(input: 'b')),
      );
    });

    group('copyWith', () {
      test('keeps values when no arguments are given', () {
        final state = _state('a b', [
          _edit('a', 'b'),
        ]).copyWith(engine: () => _engine, error: () => 'x');
        expect(state.copyWith(), state);
      });

      test('replaces every field', () {
        const result = ProofreadResult(correctedText: 'x');
        final state = const ProofreadState().copyWith(
          input: 'in',
          engine: () => _engine,
          availableEngines: [_engine],
          writingStyle: WritingStyle.email,
          correctionLevel: CorrectionLevel.light,
          formality: Formality.more,
          context: 'ctx',
          status: ProofreadStatus.failure,
          result: () => result,
          proofreadInput: 'pi',
          acceptedEdits: {0},
          error: () => 'boom',
        );
        expect(state.input, 'in');
        expect(state.engine, _engine);
        expect(state.availableEngines, [_engine]);
        expect(state.writingStyle, WritingStyle.email);
        expect(state.correctionLevel, CorrectionLevel.light);
        expect(state.formality, Formality.more);
        expect(state.context, 'ctx');
        expect(state.status, ProofreadStatus.failure);
        expect(state.result, same(result));
        expect(state.proofreadInput, 'pi');
        expect(state.acceptedEdits, {0});
        expect(state.error, 'boom');
      });

      test('clears nullable fields', () {
        final state = _state('a', const [])
            .copyWith(engine: () => _engine, error: () => 'e')
            .copyWith(
              engine: () => null,
              result: () => null,
              error: () => null,
            );
        expect(state.engine, isNull);
        expect(state.result, isNull);
        expect(state.error, isNull);
      });
    });

    group('canProofread', () {
      test('requires an engine, non-blank input and no pending request', () {
        expect(const ProofreadState(input: 'hi').canProofread, isFalse);
        expect(
          const ProofreadState(input: '  ', engine: _engine).canProofread,
          isFalse,
        );
        expect(
          const ProofreadState(input: 'hi', engine: _engine).canProofread,
          isTrue,
        );
        expect(
          const ProofreadState(
            input: 'hi',
            engine: _engine,
            status: ProofreadStatus.loading,
          ).canProofread,
          isFalse,
        );
      });
    });

    group('outputText', () {
      test('is empty without a result', () {
        expect(const ProofreadState(input: 'abc').outputText, isEmpty);
      });

      test('derives the output from the edits only', () {
        // correctedText also collapses the double space without listing it;
        // the cubit turns such changes into edits (ProofreadDiff.reconcile).
        final state = _state('I has  a apple', [
          _edit('has', 'have'),
          _edit('a apple', 'an apple'),
        ], corrected: 'I have an apple');
        expect(state.outputText, 'I have  an apple');
      });

      test('applies every accepted edit when correctedText omits them', () {
        const input = 'I has a apple and a orange';
        final edits = [
          _edit('has', 'have'),
          _edit('a apple', 'an apple'),
          _edit('a orange', 'an orange'),
        ];
        expect(
          _state(input, edits, corrected: input).outputText,
          'I have an apple and an orange',
        );
        expect(
          _state(input, edits, accepted: {0, 1}, corrected: input).outputText,
          'I have an apple and a orange',
        );
      });

      test('prefers correctedText when there are no edits', () {
        expect(_state('teh', const [], corrected: 'the').outputText, 'the');
      });

      test('applies edits when correctedText is empty', () {
        final state = _state('I has a apple', [
          _edit('has', 'have'),
          _edit('a apple', 'an apple'),
        ]);
        expect(state.outputText, 'I have an apple');
        expect(_state('unchanged', const []).outputText, 'unchanged');
      });

      test('applies only accepted edits when some are rejected', () {
        final edits = [
          _edit('has', 'have'),
          _edit('a apple', 'an apple'),
          _edit('a orange', 'an orange'),
        ];
        const input = 'I has a apple and a orange';
        const corrected = 'I have an apple and an orange';
        expect(
          _state(input, edits, accepted: {1}, corrected: corrected).outputText,
          'I has an apple and a orange',
        );
        expect(
          _state(
            input,
            edits,
            accepted: {0, 2},
            corrected: corrected,
          ).outputText,
          'I have a apple and an orange',
        );
        expect(
          _state(input, edits, accepted: {}, corrected: corrected).outputText,
          input,
        );
      });

      test('replaces repeated words at the right occurrence', () {
        final edits = [_edit('the', 'a'), _edit('the', 'a')];
        const input = 'I saw the cat and the dog.';
        expect(
          _state(input, edits, accepted: {1}).outputText,
          'I saw the cat and a dog.',
        );
        expect(
          _state(input, edits, accepted: {0}).outputText,
          'I saw a cat and the dog.',
        );
        expect(_state('the the', [_edit('the the', 'the')]).outputText, 'the');
      });

      test('skips overlapping and missing originals', () {
        final edits = [
          _edit('teh cat', 'the cat'),
          _edit('cat sat', 'cat sits'),
          _edit('nowhere', 'somewhere'),
          _edit('mat', 'rug'),
        ];
        expect(
          _state('teh cat sat on the mat', edits).outputText,
          'the cat sat on the rug',
        );
      });

      test('uses the proofread text rather than the edited input', () {
        final state = _state('I has it', [
          _edit('has', 'have'),
        ], accepted: {}).copyWith(input: 'something else');
        expect(state.outputText, 'I has it');
      });
    });

    group('isStale', () {
      test('is false without a result', () {
        expect(const ProofreadState(input: 'a').isStale, isFalse);
      });

      test('tells whether the input changed after proofreading', () {
        final state = _state('I has it', [_edit('has', 'have')]);
        expect(state.isStale, isFalse);
        expect(state.copyWith(input: 'I has it. More.').isStale, isTrue);
      });
    });

    test('compares engine details that equality of engines ignores', () {
      const remote = TranslationEngine(
        id: 'ai:openai',
        kind: EngineKind.ai,
        name: 'OpenAI',
        subtitle: 'gpt-5',
        isLocal: true,
      );
      expect(remote, _engine);
      expect(
        const ProofreadState(engine: _engine, availableEngines: [_engine]),
        isNot(const ProofreadState(engine: remote, availableEngines: [remote])),
      );
      expect(
        const ProofreadState(availableEngines: [_engine]),
        isNot(const ProofreadState(availableEngines: [remote])),
      );
    });

    test('allEditsAccepted and acceptedCount ignore stray indices', () {
      final state = _state(
        'a b c',
        [_edit('a', 'A'), _edit('b', 'B')],
        accepted: {0, 7},
      );
      expect(state.allEditsAccepted, isFalse);
      expect(state.acceptedCount, 1);
      expect(state.copyWith(acceptedEdits: {0, 1}).allEditsAccepted, isTrue);
      expect(const ProofreadState().edits, isEmpty);
    });

    group('isClean', () {
      test('is false without a result', () {
        expect(const ProofreadState().isClean, isFalse);
      });

      test('is true without edits and with the same or empty text', () {
        expect(_state('Fine.', const [], corrected: ' Fine. ').isClean, isTrue);
        expect(_state('Fine.', const []).isClean, isTrue);
      });

      test('is false with edits or a different corrected text', () {
        expect(_state('Fine.', const [], corrected: 'Good.').isClean, isFalse);
        expect(_state('a', [_edit('a', 'b')]).isClean, isFalse);
      });
    });
  });
}
