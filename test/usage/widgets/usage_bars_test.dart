import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/usage/usage.dart';

import '../../helpers/helpers.dart';

void main() {
  group('UsageBar', () {
    double widthFactor(WidgetTester tester) => tester
        .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .widthFactor!;

    Future<void> pumpBar(WidgetTester tester, double fraction) =>
        tester.pumpApp(
          Center(
            child: SizedBox(
              width: 200,
              child: UsageBar(fraction: fraction, semanticsLabel: 'bar'),
            ),
          ),
        );

    testWidgets('fills to the fraction', (tester) async {
      await pumpBar(tester, 0.4);
      expect(widthFactor(tester), 0.4);
      expect(tester.getSize(find.byType(UsageBar)).height, 8);
      expect(find.bySemanticsLabel('bar'), findsOneWidget);
    });

    testWidgets('clamps and keeps tiny values visible', (tester) async {
      await pumpBar(tester, 3);
      expect(widthFactor(tester), 1);
      await pumpBar(tester, -1);
      expect(widthFactor(tester), 0);
      await pumpBar(tester, double.nan);
      expect(widthFactor(tester), 0);
      await pumpBar(tester, 0.001);
      expect(widthFactor(tester), 0.015);
    });
  });

  group('UsageHistoryChart', () {
    testWidgets('labels months and describes values', (tester) async {
      await tester.pumpApp(
        const Center(
          child: SizedBox(
            width: 300,
            child: UsageHistoryChart(
              months: [UsageMonth(2026, 11), UsageMonth(2026, 12)],
              values: [1200, 0],
            ),
          ),
        ),
      );
      expect(find.text('Nov'), findsOneWidget);
      expect(find.text('Dec'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Characters per month: Nov: 1,200, Dec: 0'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(UsageHistoryChart),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });
  });

  group('UsageHistoryPainter', () {
    const painter = UsageHistoryPainter(
      values: [0, 5, 10],
      color: Color(0xFF000001),
      highlightColor: Color(0xFF000002),
      baselineColor: Color(0xFF000003),
    );

    void paint(UsageHistoryPainter painter) {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(120, 40));
      recorder.endRecording().dispose();
    }

    test('paints values, all zero and empty lists', () {
      paint(painter);
      paint(
        const UsageHistoryPainter(
          values: [0, 0],
          color: Color(0xFF000001),
          highlightColor: Color(0xFF000002),
          baselineColor: Color(0xFF000003),
        ),
      );
      paint(
        const UsageHistoryPainter(
          values: [],
          color: Color(0xFF000001),
          highlightColor: Color(0xFF000002),
          baselineColor: Color(0xFF000003),
        ),
      );
    });

    test('repaints only when something changed', () {
      expect(
        painter.shouldRepaint(
          const UsageHistoryPainter(
            values: [0, 5, 10],
            color: Color(0xFF000001),
            highlightColor: Color(0xFF000002),
            baselineColor: Color(0xFF000003),
          ),
        ),
        isFalse,
      );
      for (final other in const [
        UsageHistoryPainter(
          values: [0, 5, 11],
          color: Color(0xFF000001),
          highlightColor: Color(0xFF000002),
          baselineColor: Color(0xFF000003),
        ),
        UsageHistoryPainter(
          values: [0, 5, 10],
          color: Color(0xFF000009),
          highlightColor: Color(0xFF000002),
          baselineColor: Color(0xFF000003),
        ),
        UsageHistoryPainter(
          values: [0, 5, 10],
          color: Color(0xFF000001),
          highlightColor: Color(0xFF000009),
          baselineColor: Color(0xFF000003),
        ),
        UsageHistoryPainter(
          values: [0, 5, 10],
          color: Color(0xFF000001),
          highlightColor: Color(0xFF000002),
          baselineColor: Color(0xFF000009),
        ),
        UsageHistoryPainter(
          values: [0, 5, 10],
          color: Color(0xFF000001),
          highlightColor: Color(0xFF000002),
          baselineColor: Color(0xFF000003),
          rounded: false,
        ),
      ]) {
        expect(painter.shouldRepaint(other), isTrue);
      }
    });
  });
}
