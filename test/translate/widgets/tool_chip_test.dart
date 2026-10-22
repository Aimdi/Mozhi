import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

Future<void> _pump(WidgetTester tester, Widget chip) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    home: Scaffold(body: Center(child: chip)),
  ),
);

void main() {
  group('TranslateToolChip', () {
    testWidgets('is a labelled filter chip that reports taps', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        TranslateToolChip(
          icon: Icons.lightbulb_outline,
          label: 'Insights',
          tooltip: 'Hide insights',
          selected: true,
          onPressed: () => taps++,
        ),
      );
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.selected, isTrue);
      expect(find.text('Insights'), findsOneWidget);
      await tester.tap(find.byType(FilterChip));
      expect(taps, 1);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Hide insights');
      expect(tooltip.excludeFromSemantics, isFalse);
    });

    testWidgets('names itself once when the tooltip repeats the label', (
      tester,
    ) async {
      await _pump(
        tester,
        const TranslateToolChip(
          icon: Icons.fact_check_outlined,
          label: 'Check meaning',
          tooltip: 'Check meaning',
          selected: false,
          onPressed: null,
        ),
      );
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.excludeFromSemantics, isTrue);
      final chip = tester.widget<FilterChip>(find.byType(FilterChip));
      expect(chip.onSelected, isNull);
    });
  });

  group('TranslateToolRow', () {
    testWidgets('an on/off tool is a checkbox with a check mark while on', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await _pump(
        tester,
        TranslateToolRow(
          icon: Icons.lightbulb_outline,
          label: 'Insights',
          selected: true,
          onPressed: () => taps++,
        ),
      );
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(TranslateToolRow)),
        isSemantics(
          label: 'Insights',
          hasCheckedState: true,
          isChecked: true,
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
          isSelected: true,
        ),
      );
      expect(tester.getSize(find.byType(ListTile)).height, 48);
      await tester.tap(find.text('Insights'));
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('an off tool has no check mark', (tester) async {
      await _pump(
        tester,
        TranslateToolRow(
          icon: Icons.lightbulb_outline,
          label: 'Insights',
          selected: false,
          onPressed: () {},
        ),
      );
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('an unfolding row turns its chevron and says it is open', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        TranslateToolRow(
          icon: Icons.alt_route,
          label: 'Alternatives',
          expanded: true,
          onPressed: () {},
        ),
      );
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
        0.5,
      );
      expect(
        tester.getSemantics(find.byType(TranslateToolRow)),
        isSemantics(isExpanded: true),
      );
      handle.dispose();
    });

    testWidgets('a row that opens a view points to the end', (tester) async {
      await _pump(
        tester,
        const TranslateToolRow(
          icon: Icons.school_outlined,
          label: 'Explain',
          opens: true,
          onPressed: null,
        ),
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isFalse);
    });

    testWidgets('a plain row has nothing at its end', (tester) async {
      await _pump(
        tester,
        TranslateToolRow(icon: Icons.abc, label: 'Plain', onPressed: () {}),
      );
      expect(tester.widget<ListTile>(find.byType(ListTile)).trailing, isNull);
    });
  });

  group('TranslateOutputSkeleton', () {
    testWidgets('is decorative without a label', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const TranslateOutputSkeleton());
      expect(
        find.byKey(const Key('translate_output_skeleton')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Translating…'), findsNothing);
      handle.dispose();
    });

    testWidgets('names itself with a label', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const TranslateOutputSkeleton(label: 'Translating…'));
      expect(find.bySemanticsLabel('Translating…'), findsOneWidget);
      handle.dispose();
    });
  });
}
