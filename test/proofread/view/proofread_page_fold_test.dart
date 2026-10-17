import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

import '../helpers/proofread_helpers.dart';

void main() {
  /// Pumps [ProofreadView] in a [size] window with [features], then a
  /// frame more (the split follows its position after the first layout).
  Future<void> pumpWithFeatures(
    WidgetTester tester, {
    required Size size,
    required List<DisplayFeature> features,
  }) async {
    final cubit = MockProofreadCubit();
    stubProofreadCubit(cubit);
    whenListen(
      cubit,
      const Stream<ProofreadState>.empty(),
      initialState: readyState,
    );
    final translate = MockTranslateCubit();
    whenListen(
      translate,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
    setSurface(tester, size);
    tester.view.displayFeatures = features;
    addTearDown(tester.view.resetDisplayFeatures);
    await tester.pumpProofread(
      const ProofreadView(),
      translateCubit: translate,
      proofreadCubit: cubit,
      router: MockGoRouter(),
    );
    await tester.pump();
  }

  const placeholder =
      'Your corrected text and suggested edits will appear here.';

  group('ProofreadView on foldables', () {
    testWidgets('splits input and result at a vertical hinge', (tester) async {
      await pumpWithFeatures(
        tester,
        size: const Size(1114, 720),
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(540, 0, 34, 720),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.unknown,
          ),
        ],
      );
      final input = tester.getRect(find.byType(ProofreadInputCard));
      final result = tester.getRect(find.byType(ProofreadResultSection));
      expect(input.right, lessThanOrEqualTo(540));
      expect(result.left, greaterThanOrEqualTo(574));
    });

    testWidgets('uses two panes at a half-opened fold on a narrow window', (
      tester,
    ) async {
      await pumpWithFeatures(
        tester,
        size: const Size(690, 1200),
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(345, 0, 0, 1200),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      );
      // The wide layout's placeholder.
      expect(find.text(placeholder), findsOneWidget);
      final input = tester.getRect(find.byType(ProofreadInputCard));
      final result = tester.getRect(find.byType(ProofreadResultSection));
      expect(input.right, lessThanOrEqualTo(345));
      expect(result.left, greaterThanOrEqualTo(345));
    });

    testWidgets('keeps one column at a tabletop fold on a phone', (
      tester,
    ) async {
      await pumpWithFeatures(
        tester,
        size: const Size(412, 1600),
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 800, 412, 0),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      );
      expect(find.text(placeholder), findsNothing);
    });
  });
}
