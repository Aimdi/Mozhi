import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

import '../../helpers/helpers.dart';

void main() {
  group('AppShell', () {
    final theme = buildAppTheme(
      appColorScheme(brightness: Brightness.light, seedColor: kDefaultAccent),
    );

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
        theme: theme,
      );
      return selected;
    }

    Finder navIcon(IconData icon) => find.byIcon(icon);

    testWidgets('uses an icon-only bottom bar on a blur bar on phones', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpShell(tester, width: 400);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('body'), findsOneWidget);
      final blur = tester.widget<BlurBar>(find.byType(BlurBar));
      expect(blur.top, isTrue);
      expect(
        find.descendant(
          of: find.byType(BlurBar),
          matching: find.byType(NavigationBar),
        ),
        findsOneWidget,
      );
      expect(
        theme.navigationBarTheme.labelBehavior,
        NavigationDestinationLabelBehavior.alwaysHide,
      );
      // Labels are hidden visually but still name each destination.
      for (final label in ['Translate', 'Proofread', 'History', 'Settings']) {
        expect(find.bySemanticsLabel(RegExp(label)), findsOneWidget);
      }
      handle.dispose();
    });

    testWidgets('uses a collapsed icon sidebar from 840 dp', (tester) async {
      await pumpShell(tester, width: 840);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('body'), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isFalse);
      expect(rail.labelType, NavigationRailLabelType.none);
      expect(find.bySemanticsLabel('Mozhi'), findsOneWidget);
      // A hairline separates the sidebar from the page.
      expect(tester.widget<Hairline>(find.byType(Hairline)).vertical, isTrue);
      // The collapsed sidebar marks the selection with an accent bar.
      expect(find.byKey(const Key('nav_icon_marker')), findsOneWidget);
    });

    testWidgets('extends the sidebar with bold labels on wide screens', (
      tester,
    ) async {
      await pumpShell(tester, width: 1400);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isTrue);
      expect(rail.labelType, NavigationRailLabelType.none);
      expect(find.text('Mozhi'), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);
      // Bold labels replace the marker.
      expect(find.byKey(const Key('nav_icon_marker')), findsNothing);
      final style = DefaultTextStyle.of(tester.element(find.text('Translate')))
          .style;
      expect(style.fontWeight, FontWeight.w800);
      expect(AppShell.extendedBreakpoint, 1200);
    });

    testWidgets('reports the tapped destination (bar)', (tester) async {
      final selected = await pumpShell(tester, width: 400);

      await tester.tap(navIcon(Icons.history_outlined));
      await tester.tap(navIcon(Icons.settings_outlined));

      expect(selected, [2, 3]);
    });

    testWidgets('reports the tapped destination (rail)', (tester) async {
      final selected = await pumpShell(tester, width: 1000, selectedIndex: 2);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 2);
      await tester.tap(navIcon(Icons.spellcheck_outlined));

      expect(selected, [1]);
    });

    testWidgets('marks the selected destination', (tester) async {
      await pumpShell(tester, width: 400, selectedIndex: 1);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
      expect(find.byIcon(Icons.spellcheck), findsOneWidget);
      expect(find.byIcon(Icons.translate_outlined), findsOneWidget);
      final marker = find.byKey(const Key('nav_icon_marker'));
      expect(marker, findsOneWidget);
      expect(
        find.ancestor(of: marker, matching: find.byType(NavIcon)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<NavIcon>(
              find.ancestor(of: marker, matching: find.byType(NavIcon)),
            )
            .icon,
        Icons.spellcheck,
      );
    });
  });

  group('NavIcon', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool selected,
      bool reduceMotion = false,
      bool marker = true,
    }) => tester.pumpApp(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Center(
          child: NavIcon(icon: Icons.home, selected: selected, marker: marker),
        ),
      ),
    );

    testWidgets('fades and scales in when selected', (tester) async {
      await pump(tester, selected: false);
      expect(find.byKey(const Key('nav_icon_marker')), findsNothing);

      await pump(tester, selected: true);
      final switcher = tester.widget<AnimatedSwitcher>(
        find.byType(AnimatedSwitcher),
      );
      expect(switcher.duration, NavIcon.duration);
      await tester.pump(const Duration(milliseconds: 50));
      // Mid-transition both states are in the tree.
      expect(find.byType(FadeTransition), findsWidgets);
      expect(find.byType(ScaleTransition), findsWidgets);
      expect(find.byIcon(Icons.home), findsNWidgets(2));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.home), findsOneWidget);
      expect(find.byKey(const Key('nav_icon_marker')), findsOneWidget);
    });

    testWidgets('switches instantly with reduced motion', (tester) async {
      await pump(tester, selected: false, reduceMotion: true);
      await pump(tester, selected: true, reduceMotion: true);
      expect(
        tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
        Duration.zero,
      );
      await tester.pump();
      expect(find.byIcon(Icons.home), findsOneWidget);
    });

    testWidgets('can go without the marker', (tester) async {
      await pump(tester, selected: true, marker: false);
      expect(find.byKey(const Key('nav_icon_marker')), findsNothing);
      expect(find.byIcon(Icons.home), findsOneWidget);
    });
  });
}
