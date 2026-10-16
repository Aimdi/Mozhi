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
}
