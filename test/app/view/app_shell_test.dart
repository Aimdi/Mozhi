import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/app_shell.dart';

import '../../helpers/helpers.dart';

void main() {
  group('AppShell', () {
    Future<List<int>> pumpShell(
      WidgetTester tester, {
      required double width,
      int selectedIndex = 0,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <int>[];
      await tester.pumpApp(
        AppShell(
          selectedIndex: selectedIndex,
          onDestinationSelected: selected.add,
          child: const Text('body'),
        ),
      );
      return selected;
    }

    testWidgets('uses a bottom navigation bar on phones', (tester) async {
      await pumpShell(tester, width: 400);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('body'), findsOneWidget);
      for (final label in ['Translate', 'Proofread', 'History', 'Settings']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('uses a navigation rail from 840 dp', (tester) async {
      await pumpShell(tester, width: 840);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('body'), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isFalse);
      expect(find.bySemanticsLabel('Mozhi'), findsOneWidget);
    });

    testWidgets('extends the rail on wide screens', (tester) async {
      await pumpShell(tester, width: 1400);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isTrue);
      expect(rail.labelType, NavigationRailLabelType.none);
      expect(find.text('Mozhi'), findsOneWidget);
    });

    testWidgets('reports the tapped destination (bar)', (tester) async {
      final selected = await pumpShell(tester, width: 400);

      await tester.tap(find.text('History'));
      await tester.tap(find.text('Settings'));

      expect(selected, [2, 3]);
    });

    testWidgets('reports the tapped destination (rail)', (tester) async {
      final selected = await pumpShell(tester, width: 1000, selectedIndex: 2);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 2);
      await tester.tap(find.text('Proofread'));

      expect(selected, [1]);
    });

    testWidgets('marks the selected destination', (tester) async {
      await pumpShell(tester, width: 400, selectedIndex: 1);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
      expect(find.byIcon(Icons.spellcheck), findsOneWidget);
      expect(find.byIcon(Icons.translate_outlined), findsOneWidget);
    });
  });
}
