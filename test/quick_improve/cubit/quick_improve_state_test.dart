import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/quick_improve/quick_improve.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  group('QuickImproveState', () {
    test('starts waiting for the engines', () {
      const state = QuickImproveState(text: sentence);
      expect(state.status, QuickImproveStatus.loadingEngines);
      expect(state.level, CorrectionLevel.standard);
      expect(state.style, WritingStyle.general);
      expect(state.hasResult, isFalse);
      expect(state.isUnchanged, isFalse);
      expect(state.canImprove, isFalse);
      expect(state.maskedPersonalData, 0);
    });

    test('can improve with an engine and text, while not improving', () {
      const state = QuickImproveState(text: sentence, engine: claude);
      expect(state.canImprove, isTrue);
      expect(
        state.copyWith(status: QuickImproveStatus.improving).canImprove,
        isFalse,
      );
      expect(
        const QuickImproveState(text: ' ', engine: claude).canImprove,
        isFalse,
      );
    });

    test('has a result once one arrived', () {
      final state = improvedState();
      expect(state.hasResult, isTrue);
      expect(state.isUnchanged, isFalse);
      expect(state.isImproving, isFalse);
      expect(
        improvedState(
          improved: sentence,
          result: const ProofreadResult(correctedText: sentence),
        ).isUnchanged,
        isTrue,
      );
      expect(
        state.copyWith(status: QuickImproveStatus.failure).hasResult,
        isFalse,
      );
    });

    test('counts the personal data the shield kept', () {
      final state = improvedState(result: fixed.withMaskedPersonalData(3));
      expect(state.maskedPersonalData, 3);
    });

    test('copyWith replaces only what it is given', () {
      final state = improvedState();
      expect(state.copyWith(), state);
      final cleared = state.copyWith(
        engine: () => null,
        result: () => null,
        error: () => 'x',
        engines: const [],
        level: CorrectionLevel.light,
        style: WritingStyle.email,
        improvedText: '',
        segments: const [],
      );
      expect(cleared.engine, isNull);
      expect(cleared.result, isNull);
      expect(cleared.error, 'x');
      expect(cleared.engines, isEmpty);
      expect(cleared.level, CorrectionLevel.light);
      expect(cleared.style, WritingStyle.email);
      expect(cleared.improvedText, isEmpty);
      expect(cleared.segments, isEmpty);
      expect(cleared.text, sentence);
    });

    test('compares every engine detail', () {
      const edited = TranslationEngine(
        id: 'ai:claude',
        kind: EngineKind.ai,
        name: 'Claude',
        subtitle: 'claude-sonnet',
        providerId: 'claude',
      );
      expect(
        const QuickImproveState(text: sentence, engine: claude),
        isNot(const QuickImproveState(text: sentence, engine: edited)),
      );
    });
  });
}
