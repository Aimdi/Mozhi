import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/terminal_rule.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

class _RecordingCanvas extends Fake implements Canvas {
  final rects = <Rect>[];
  final colors = <Color>[];

  @override
  void drawRect(Rect rect, Paint paint) {
    rects.add(rect);
    colors.add(paint.color);
  }
}

void main() {
  group('TerminalRule', () {
    const palette = AppPalette(
      hairline: Color(0xFF3A372F),
      secondaryText: Color(0xFFA39A86),
      like: Color(0xFFF91880),
      success: Color(0xFF00BA7C),
      barBackground: Color(0xFF0B0B0B),
    );

    Future<void> pump(WidgetTester tester, Widget rule) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [palette]),
        home: Scaffold(
          body: Center(child: SizedBox(width: 200, height: 100, child: rule)),
        ),
      ),
    );

    testWidgets('is a 1 px line across the width', (tester) async {
      await pump(tester, const Align(child: TerminalRule()));

      final size = tester.getSize(find.byType(TerminalRule));
      expect(size, const Size(200, 1));
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(TerminalRule),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = paint.painter! as TerminalRulePainter;
      expect(painter.color, palette.hairline);
      expect(painter.axis, Axis.horizontal);
    });

    testWidgets('can run down the height', (tester) async {
      await pump(tester, const Align(child: TerminalRule(axis: Axis.vertical)));

      expect(tester.getSize(find.byType(TerminalRule)), const Size(1, 100));
    });

    testWidgets('takes a colour of its own', (tester) async {
      await pump(tester, const TerminalRule(color: Color(0xFFFFB000)));

      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(TerminalRule),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(
        (paint.painter! as TerminalRulePainter).color,
        const Color(0xFFFFB000),
      );
    });

    testWidgets('is nothing for screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const TerminalRule());

      final node = tester.getSemantics(find.byType(TerminalRule));
      expect(node.label, isEmpty);
      handle.dispose();
    });
  });

  group('TerminalRulePainter', () {
    const color = Color(0xFF3A372F);

    test('paints dashes along the line, the last one cut at the end', () {
      final canvas = _RecordingCanvas();
      const TerminalRulePainter(color: color).paint(canvas, const Size(20, 1));

      expect(canvas.rects, const [
        Rect.fromLTRB(0, 0, 4, 1),
        Rect.fromLTRB(7, 0, 11, 1),
        Rect.fromLTRB(14, 0, 18, 1),
      ]);
      expect(canvas.colors, everyElement(isSameColorAs(color)));

      final cut = _RecordingCanvas();
      const TerminalRulePainter(color: color).paint(cut, const Size(16, 1));
      expect(cut.rects.last, const Rect.fromLTRB(14, 0, 16, 1));
    });

    test('paints down a vertical line', () {
      final canvas = _RecordingCanvas();
      const TerminalRulePainter(
        color: color,
        axis: Axis.vertical,
        dash: 2,
        gap: 2,
      ).paint(canvas, const Size(1, 8));

      expect(canvas.rects, const [
        Rect.fromLTRB(0, 0, 1, 2),
        Rect.fromLTRB(0, 4, 1, 6),
      ]);
    });

    test('paints nothing on an empty box or without dashes', () {
      final canvas = _RecordingCanvas();
      const TerminalRulePainter(color: color).paint(canvas, Size.zero);
      const TerminalRulePainter(
        color: color,
        dash: 0,
      ).paint(canvas, const Size(20, 1));
      expect(canvas.rects, isEmpty);
    });

    test('a negative gap draws a solid line of dashes', () {
      final canvas = _RecordingCanvas();
      const TerminalRulePainter(
        color: color,
        gap: -1,
      ).paint(canvas, const Size(8, 1));
      expect(canvas.rects, const [
        Rect.fromLTRB(0, 0, 4, 1),
        Rect.fromLTRB(4, 0, 8, 1),
      ]);
    });

    test('repaints when it changes', () {
      const painter = TerminalRulePainter(color: color);
      expect(
        painter.shouldRepaint(const TerminalRulePainter(color: color)),
        isFalse,
      );
      expect(
        painter.shouldRepaint(const TerminalRulePainter(color: Colors.red)),
        isTrue,
      );
      expect(
        painter.shouldRepaint(
          const TerminalRulePainter(color: color, axis: Axis.vertical),
        ),
        isTrue,
      );
      expect(
        painter.shouldRepaint(const TerminalRulePainter(color: color, dash: 6)),
        isTrue,
      );
      expect(
        painter.shouldRepaint(const TerminalRulePainter(color: color, gap: 1)),
        isTrue,
      );
    });
  });
}
