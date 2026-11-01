import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_colors.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_text.dart';

import '../../helpers/helpers.dart';

void main() {
  group('ProofreadDiffText', () {
    const segments = [
      DiffSegment.unchanged('I '),
      DiffSegment.removed('has', editIndex: 0),
      DiffSegment.inserted('have', editIndex: 0),
      DiffSegment.inserted('!'),
    ];

    List<TextSpan> spans(WidgetTester tester) {
      final text = tester.widget<RichText>(find.byType(RichText));
      final result = <TextSpan>[];
      text.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) result.add(span);
        return true;
      });
      return result;
    }

    testWidgets('styles and labels the changes', (tester) async {
      await tester.pumpApp(
        const Scaffold(body: ProofreadDiffText(segments: segments)),
      );
      final colors = ProofreadDiffColors.of(
        tester.element(find.byType(ProofreadDiffText)),
      );
      final shown = spans(tester);
      expect(shown.map((s) => s.text), ['I ', 'has', 'have', '!']);
      expect(shown[0].style, isNull);
      expect(shown[0].semanticsLabel, isNull);
      expect(shown[1].style, colors.removedStyle);
      expect(shown[1].semanticsLabel, 'removed: has');
      expect(shown[2].style, colors.insertedStyle);
      expect(shown[2].semanticsLabel, 'added: have');
      expect(shown.every((s) => s.recognizer == null), isTrue);
    });

    testWidgets('opens the edit of a change', (tester) async {
      final tapped = <int>[];
      await tester.pumpApp(
        Scaffold(
          body: ProofreadDiffText(segments: segments, onEditTap: tapped.add),
        ),
      );
      final shown = spans(tester);
      expect(shown[0].recognizer, isNull);
      expect(shown[3].recognizer, isNull);
      (shown[2].recognizer! as TapGestureRecognizer).onTap!();
      expect(tapped, [0]);
    });
  });

  group('ProofreadDiffColors', () {
    testWidgets('fall back to the inserted colors for rephrasings', (
      tester,
    ) async {
      const colors = ProofreadDiffColors(
        removedBackground: Colors.red,
        removedForeground: Colors.white,
        insertedBackground: Colors.green,
        insertedForeground: Colors.black,
      );
      expect(colors.rephrasedStyle.backgroundColor, Colors.green);
      expect(colors.rephrasedStyle.color, Colors.black);
      expect(colors.rephrasedStyle.decorationStyle, TextDecorationStyle.dotted);
      expect(colors.styleFor(DiffType.unchanged), isNull);
    });
  });
}
