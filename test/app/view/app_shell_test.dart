import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/app/view/app_shell.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/widgets/terminal_rule.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../../helpers/helpers.dart';

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

void main() {
  group('AppShell', () {
    final theme = buildAppTheme(
      appColorScheme(brightness: Brightness.light, seedColor: kDefaultAccent),
    );

    Future<List<int>> pumpShell(
      WidgetTester tester, {
      required double width,
      int selectedIndex = 0,
      List<AppTab>? order,
      SettingsCubit? settings,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <int>[];
      final shell = AppShell(
        selectedIndex: selectedIndex,
        onDestinationSelected: selected.add,
        order: order,
        child: const Text('body'),
      );
      await tester.pumpApp(
        settings == null
            ? shell
            : BlocProvider<SettingsCubit>.value(value: settings, child: shell),
        theme: theme,
      );
      return selected;
    }

    List<String> barLabels(WidgetTester tester) => tester
        .widget<NavigationBar>(find.byType(NavigationBar))
        .destinations
        .cast<NavigationDestination>()
        .map((d) => d.label)
        .toList();

    Finder navIcon(IconData icon) => find.byIcon(icon);

    testWidgets('uses a labelled bottom bar on a blur bar on phones', (
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
        NavigationDestinationLabelBehavior.alwaysShow,
      );
      // Each destination shows its name and is named by it.
      for (final label in [
        'Translate',
        'Dictionary',
        'Proofread',
        'Conversation',
      ]) {
        expect(find.text(label), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(label)), findsOneWidget);
      }
      // History and Settings are app bar actions, not destinations.
      expect(find.bySemanticsLabel(RegExp('History|Settings')), findsNothing);
      handle.dispose();
    });

    testWidgets('uses a collapsed sidebar with small labels from 840 dp', (
      tester,
    ) async {
      await pumpShell(tester, width: 840);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('body'), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isFalse);
      expect(rail.labelType, NavigationRailLabelType.all);
      for (final label in [
        'Translate',
        'Dictionary',
        'Proofread',
        'Conversation',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      // Small labels under the icons, bold when selected.
      expect(rail.selectedLabelTextStyle?.fontWeight, FontWeight.w800);
      expect(rail.unselectedLabelTextStyle?.fontWeight, FontWeight.w500);
      final label = DefaultTextStyle.of(tester.element(find.text('Translate')))
          .style;
      expect(label.fontSize, 12);
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
      // The theme's bold labels.
      expect(rail.selectedLabelTextStyle, isNull);
      expect(find.text('Mozhi'), findsOneWidget);
      expect(find.text('Translate'), findsOneWidget);
      // Bold labels replace the marker.
      expect(find.byKey(const Key('nav_icon_marker')), findsNothing);
      final style = DefaultTextStyle.of(tester.element(find.text('Translate')))
          .style;
      expect(style.fontWeight, FontWeight.w800);
      expect(AppShell.extendedBreakpoint, 1200);
    });

    testWidgets('lists Translate, Dictionary, Proofread, Conversation', (
      tester,
    ) async {
      expect(AppDestination.all.map((d) => d.icon), [
        Icons.translate_outlined,
        Icons.menu_book_outlined,
        Icons.spellcheck_outlined,
        Icons.forum_outlined,
      ]);
      expect(AppDestination.all.map((d) => d.selectedIcon), [
        Icons.translate,
        Icons.menu_book,
        Icons.spellcheck,
        Icons.forum,
      ]);
      await pumpShell(tester, width: 400);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(
        bar.destinations
            .cast<NavigationDestination>()
            .map((d) => d.label)
            .toList(),
        ['Translate', 'Dictionary', 'Proofread', 'Conversation'],
      );
      // Each destination names itself in a tooltip as well.
      for (final label in bar.destinations.cast<NavigationDestination>().map(
        (d) => d.label,
      )) {
        expect(
          find.byWidgetPredicate((w) => w is Tooltip && w.message == label),
          findsOneWidget,
        );
      }
    });

    testWidgets('reports the tapped destination (bar)', (tester) async {
      final selected = await pumpShell(tester, width: 400);

      await tester.tap(navIcon(Icons.menu_book_outlined));
      await tester.tap(navIcon(Icons.spellcheck_outlined));
      await tester.tap(navIcon(Icons.forum_outlined));

      expect(selected, [1, 2, 3]);
    });

    testWidgets('reports the tapped destination (rail)', (tester) async {
      final selected = await pumpShell(tester, width: 1000, selectedIndex: 3);

      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 3);
      await tester.tap(navIcon(Icons.spellcheck_outlined));
      await tester.tap(navIcon(Icons.menu_book_outlined));

      expect(selected, [2, 1]);
    });

    group('tab order', () {
      const order = [
        AppTab.proofread,
        AppTab.translate,
        AppTab.conversation,
        AppTab.dictionary,
      ];

      testWidgets('shows the destinations in the given order', (tester) async {
        await pumpShell(tester, width: 400, order: order);

        expect(barLabels(tester), [
          'Proofread',
          'Translate',
          'Conversation',
          'Dictionary',
        ]);
      });

      testWidgets('maps the bar to the branch indexes', (tester) async {
        // Branch 2 (Proofread) is shown first.
        final selected = await pumpShell(
          tester,
          width: 400,
          order: order,
          selectedIndex: 2,
        );

        final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar.selectedIndex, 0);
        await tester.tap(navIcon(Icons.menu_book_outlined));
        await tester.tap(navIcon(Icons.translate_outlined));
        await tester.tap(navIcon(Icons.forum_outlined));
        expect(selected, [1, 0, 3]);
      });

      testWidgets('maps the rail to the branch indexes', (tester) async {
        final selected = await pumpShell(
          tester,
          width: 1000,
          order: order,
          selectedIndex: 1,
        );

        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        expect(rail.selectedIndex, 3);
        await tester.tap(navIcon(Icons.spellcheck_outlined));
        expect(selected, [2]);
      });

      testWidgets("follows the user's order from the settings", (tester) async {
        final settings = MockSettingsCubit();
        whenListen(
          settings,
          Stream.fromIterable(const [
            AppSettings(
              tabOrder: [
                AppTab.conversation,
                AppTab.translate,
                AppTab.dictionary,
                AppTab.proofread,
              ],
            ),
          ]),
          initialState: const AppSettings(tabOrder: order),
        );
        await pumpShell(tester, width: 400, settings: settings);
        expect(barLabels(tester).first, 'Proofread');

        await tester.pump();
        expect(barLabels(tester), [
          'Conversation',
          'Translate',
          'Dictionary',
          'Proofread',
        ]);
      });

      testWidgets('uses the default order without settings', (tester) async {
        await pumpShell(tester, width: 400);
        expect(barLabels(tester), [
          'Translate',
          'Dictionary',
          'Proofread',
          'Conversation',
        ]);
      });

      testWidgets('completes an incomplete order', (tester) async {
        await pumpShell(tester, width: 400, order: const [AppTab.conversation]);
        expect(barLabels(tester), [
          'Conversation',
          'Translate',
          'Dictionary',
          'Proofread',
        ]);
      });

      test('maps every tab to its destination', () {
        for (final tab in AppTab.values) {
          expect(AppDestination.of(tab), AppDestination.all[tab.index]);
        }
      });
    });

    testWidgets('marks the selected destination', (tester) async {
      await pumpShell(tester, width: 400, selectedIndex: 2);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 2);
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

    group('edge to edge', () {
      // A cutout at the left, three-button navigation at the right and a
      // gesture bar below, as drawn behind the system bars.
      const padding = FakeViewPadding(left: 24, top: 30, right: 48, bottom: 20);
      const tab = Key('tab');

      Future<void> pumpPadded(
        WidgetTester tester, {
        required double width,
        TextDirection direction = TextDirection.ltr,
      }) async {
        tester.view
          ..physicalSize = Size(width, 900)
          ..devicePixelRatio = 1
          ..padding = padding
          ..viewPadding = padding;
        addTearDown(tester.view.reset);
        await tester.pumpApp(
          Directionality(
            textDirection: direction,
            child: AppShell(
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              child: const SizedBox.expand(key: tab),
            ),
          ),
          theme: theme,
        );
      }

      EdgeInsets tabPadding(WidgetTester tester) =>
          MediaQuery.paddingOf(tester.element(find.byKey(tab)));

      testWidgets('keeps the tab and the rail clear of the system bars', (
        tester,
      ) async {
        await pumpPadded(tester, width: 1000);

        final rail = tester.getRect(find.byType(NavigationRail));
        expect(rail.left, 24);
        expect(rail.bottom, 900 - 20);
        final body = tester.getRect(find.byKey(tab));
        // The app bar covers the top.
        expect(body.top, 0);
        expect(body.left, greaterThan(rail.right));
        expect(body.right, 1000 - 48);
        expect(body.bottom, 900 - 20);
        // Nothing inside pads again, but for the app bar.
        expect(tabPadding(tester), const EdgeInsets.only(top: 30));
      });

      testWidgets('puts the rail on the right in right-to-left languages', (
        tester,
      ) async {
        await pumpPadded(tester, width: 1000, direction: TextDirection.rtl);

        final rail = tester.getRect(find.byType(NavigationRail));
        expect(rail.right, 1000 - 48);
        final body = tester.getRect(find.byKey(tab));
        expect(body.left, 24);
        expect(body.right, lessThan(rail.left));
        expect(body.bottom, 900 - 20);
        expect(tabPadding(tester), const EdgeInsets.only(top: 30));
      });

      testWidgets('keeps the tab clear of the sides above the bottom bar', (
        tester,
      ) async {
        await pumpPadded(tester, width: 400);

        final body = tester.getRect(find.byKey(tab));
        expect(body.left, 24);
        expect(body.right, 400 - 48);
        expect(body.bottom, tester.getRect(find.byType(BlurBar)).top);
        // The bar pads itself below; nothing in the tab pads again.
        expect(tabPadding(tester), const EdgeInsets.only(top: 30));
      });
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

  group('AppShell labels', () {
    final theme = buildAppTheme(
      appColorScheme(brightness: Brightness.light, seedColor: kDefaultAccent),
    );

    /// The shell at [width] in [locale] with [textScale], in the app theme.
    Future<void> pumpLocalized(
      WidgetTester tester, {
      required double width,
      required Locale locale,
      double textScale = 1,
    }) async {
      tester.view
        ..physicalSize = Size(width, 700)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          locale: locale,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: AppShell(
              selectedIndex: 3,
              onDestinationSelected: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final locale in const [
      Locale('ta'),
      Locale('it'),
      Locale('de'),
      Locale('en'),
    ]) {
      testWidgets('fit one line each on a 320 dp phone ($locale)', (
        tester,
      ) async {
        await pumpLocalized(tester, width: 320, locale: locale, textScale: 2);
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byType(NavigationBar));
        expect(bar.height, greaterThanOrEqualTo(kNavigationBarHeight));
        final labels = find.descendant(
          of: find.byType(NavigationBar),
          matching: find.byType(Text),
        );
        expect(labels, findsNWidgets(4));
        for (final element in labels.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          final paragraph = element.renderObject! as RenderParagraph;
          // One line, within its quarter of the bar and the bar itself.
          expect(
            paragraph.text.style?.overflow ?? TextOverflow.ellipsis,
            TextOverflow.ellipsis,
          );
          expect(
            rect.height,
            lessThanOrEqualTo(paragraph.textScaler.scale(12) * 2),
            reason: '${(element.widget as Text).data} wraps',
          );
          expect(rect.width, lessThanOrEqualTo(320 / 4));
          expect(rect.bottom, lessThanOrEqualTo(bar.bottom));
        }
      });
    }

    testWidgets('the collapsed sidebar fits long labels', (tester) async {
      await pumpLocalized(
        tester,
        width: 900,
        locale: const Locale('ta'),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('உரையாடல்'), findsOneWidget);
    });
  });

  group('AppShell keyboard', () {
    final theme = buildAppTheme(
      appColorScheme(brightness: Brightness.light, seedColor: kDefaultAccent),
    );

    /// The shell at [width] in a router with a History page; returns the
    /// branch indexes it reported.
    Future<List<int>> pumpRouted(
      WidgetTester tester, {
      double width = 400,
      List<AppTab>? order,
      Widget body = const SizedBox.expand(),
    }) async {
      tester.view
        ..physicalSize = Size(width, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <int>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => AppShell(
              selectedIndex: 0,
              order: order,
              onDestinationSelected: selected.add,
              child: body,
            ),
          ),
          GoRoute(
            path: AppRoutes.history,
            builder: (context, state) => const Text('History page'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          theme: theme,
          localizationsDelegates: appLocalizationsDelegates,
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
      return selected;
    }

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool control = true,
      bool shift = true,
      bool alt = false,
    }) async {
      final modifiers = [
        if (control) LogicalKeyboardKey.controlLeft,
        if (shift) LogicalKeyboardKey.shiftLeft,
        if (alt) LogicalKeyboardKey.altLeft,
      ];
      for (final modifier in modifiers) {
        await tester.sendKeyDownEvent(modifier);
      }
      await tester.sendKeyEvent(key);
      for (final modifier in modifiers.reversed) {
        await tester.sendKeyUpEvent(modifier);
      }
      await tester.pumpAndSettle();
    }

    test('lists Ctrl+Shift+1 … 4 and Ctrl+Shift+H', () {
      expect(AppShell.tabShortcuts, hasLength(4));
      for (final (i, shortcut) in AppShell.tabShortcuts.indexed) {
        expect(shortcut.control && shortcut.shift, isTrue);
        expect(shortcut.alt || shortcut.meta, isFalse);
        expect(
          shortcut.trigger,
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
          ][i],
        );
      }
      expect(AppShell.historyShortcut.trigger, LogicalKeyboardKey.keyH);
      expect(AppShell.historyShortcut.control, isTrue);
      expect(AppShell.historyShortcut.shift, isTrue);
    });

    testWidgets("Ctrl+Shift+digit opens the tab at that place of the user's "
        'order', (tester) async {
      final selected = await pumpRouted(
        tester,
        order: const [
          AppTab.proofread,
          AppTab.translate,
          AppTab.conversation,
          AppTab.dictionary,
        ],
      );
      await press(tester, LogicalKeyboardKey.digit1);
      await press(tester, LogicalKeyboardKey.digit4);
      await press(tester, LogicalKeyboardKey.digit3);
      expect(selected, [
        AppTab.proofread.index,
        AppTab.dictionary.index,
        AppTab.conversation.index,
      ]);
    });

    testWidgets('Ctrl+Shift+digit works beside the sidebar too', (
      tester,
    ) async {
      final selected = await pumpRouted(tester, width: 1000);
      await press(tester, LogicalKeyboardKey.digit2);
      expect(selected, [AppTab.dictionary.index]);
    });

    testWidgets('other modifiers and keys do nothing', (tester) async {
      final selected = await pumpRouted(tester);
      // Alt+digit is the translate tab's (pinned languages) and the
      // browser's.
      await press(
        tester,
        LogicalKeyboardKey.digit2,
        control: false,
        shift: false,
        alt: true,
      );
      // Ctrl+digit is the browser's.
      await press(tester, LogicalKeyboardKey.digit2, shift: false);
      await press(tester, LogicalKeyboardKey.digit5);
      await press(tester, LogicalKeyboardKey.keyJ);
      expect(selected, isEmpty);
      expect(find.text('History page'), findsNothing);
    });

    testWidgets('work while typing, and type nothing', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final selected = await pumpRouted(
        tester,
        body: Material(
          child: TextField(controller: controller, autofocus: true),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Hi');
      await press(tester, LogicalKeyboardKey.digit2);
      expect(selected, [AppTab.dictionary.index]);
      expect(controller.text, 'Hi');
    });

    testWidgets('Ctrl+Shift+H opens History', (tester) async {
      await pumpRouted(tester, width: 1000);
      await press(tester, LogicalKeyboardKey.keyH);
      expect(find.text('History page'), findsOneWidget);

      // Not from History itself (the tabs are below it).
      await press(tester, LogicalKeyboardKey.keyH);
      expect(find.text('History page'), findsOneWidget);
    });

    testWidgets('wait while a dialog is open above the tabs', (tester) async {
      final selected = await pumpRouted(tester);
      final context = tester.element(find.byType(AppShell));
      showDialog<void>(
        context: context,
        builder: (context) => const AlertDialog(content: Text('Dialog')),
      ).ignore();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.digit2);
      await press(tester, LogicalKeyboardKey.keyH);
      expect(selected, isEmpty);
      expect(find.text('History page'), findsNothing);
    });

    testWidgets('need a router for History', (tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpApp(
        AppShell(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          child: const SizedBox.expand(),
        ),
        theme: theme,
      );
      await press(tester, LogicalKeyboardKey.keyH);
      expect(tester.takeException(), isNull);
    });

    /// The labels of the focused controls, pressing Tab [count] times.
    Future<List<String>> tabThrough(WidgetTester tester, int count) async {
      final labels = <String>[];
      for (var i = 0; i < count; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focus = FocusManager.instance.primaryFocus!;
        final text = find.descendant(
          of: find.byElementPredicate((element) => element == focus.context),
          matching: find.byType(Text),
        );
        labels.add(
          text.evaluate().isEmpty
              ? focus.toString()
              : (text.evaluate().first.widget as Text).data!,
        );
      }
      return labels;
    }

    Widget tabBody() => Scaffold(
      appBar: AppBar(
        title: const Text('Tab'),
        actions: [TextButton(onPressed: () {}, child: const Text('Bar'))],
      ),
      body: Center(
        child: TextButton(onPressed: () {}, child: const Text('Content')),
      ),
    );

    testWidgets('Tab goes through the sidebar, then the app bar and content', (
      tester,
    ) async {
      await pumpRouted(tester, width: 1000, body: tabBody());
      expect(await tabThrough(tester, 6), [
        'Translate',
        'Dictionary',
        'Proofread',
        'Conversation',
        'Bar',
        'Content',
      ]);
    });

    testWidgets('on phones through the tab, then the bottom bar', (
      tester,
    ) async {
      await pumpRouted(tester, body: tabBody());
      expect(await tabThrough(tester, 6), [
        'Bar',
        'Content',
        'Translate',
        'Dictionary',
        'Proofread',
        'Conversation',
      ]);
    });
  });

  group('AppShell in the terminal look', () {
    final theme = buildAppTheme(
      appColorScheme(
        brightness: Brightness.dark,
        seedColor: const Color(0xFFFFB000),
      ),
      look: AppLook.terminal,
    );

    Future<List<int>> pumpShell(
      WidgetTester tester, {
      required double width,
      double height = 900,
      int selectedIndex = 0,
      double textScale = 1,
      Locale? locale,
    }) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          locale: locale,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: AppShell(
            selectedIndex: selectedIndex,
            onDestinationSelected: selected.add,
            child: Scaffold(
              appBar: AppBar(actions: const [TopLevelActions()]),
              body: const Text('body'),
            ),
          ),
        ),
      );
      return selected;
    }

    testWidgets('numbers the tabs under a dashed rule on phones', (
      tester,
    ) async {
      await pumpShell(tester, width: 390);

      final bar = find.byKey(const Key('terminal_navigation_bar'));
      expect(bar, findsOneWidget);
      expect(find.byType(BlurBar), findsNothing);
      expect(find.byType(TerminalRule), findsOneWidget);
      // The rule is right above the bar.
      expect(
        tester.getBottomLeft(find.byType(TerminalRule)).dy,
        tester.getTopLeft(bar).dy,
      );
      for (final label in [
        '1:translate',
        '2:dictionary',
        '3:proofread',
        '4:conversation',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      // No icons.
      expect(find.byIcon(Icons.translate_outlined), findsNothing);
      expect(find.byIcon(Icons.translate), findsNothing);
      expect(
        tester.widget<NavigationBar>(bar).labelBehavior,
        NavigationDestinationLabelBehavior.alwaysHide,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('marks the selected tab with an accent block', (tester) async {
      await pumpShell(tester, width: 390, selectedIndex: 2);

      final block = find.byKey(const Key('terminal_nav_selected'));
      expect(block, findsOneWidget);
      expect(
        find.descendant(of: block, matching: find.text('3:proofread')),
        findsOneWidget,
      );
      final decoration =
          tester.widget<DecoratedBox>(block).decoration as BoxDecoration;
      final scheme = theme.colorScheme;
      expect(decoration.color, scheme.primary);
      final selected = tester.widget<Text>(find.text('3:proofread'));
      expect(selected.style?.color, scheme.onPrimary);
      expect(selected.style?.fontWeight, FontWeight.w700);
      final other = tester.widget<Text>(find.text('1:translate'));
      expect(other.style?.fontWeight, FontWeight.w500);
      expect(other.style?.color, isNot(scheme.onPrimary));
    });

    testWidgets('keeps the names of the tabs for screen readers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpShell(tester, width: 390, selectedIndex: 1);

      for (final label in [
        'Translate',
        'Dictionary',
        'Proofread',
        'Conversation',
      ]) {
        expect(find.bySemanticsLabel(RegExp('^$label')), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is Tooltip && w.message == label),
          findsOneWidget,
        );
      }
      expect(find.bySemanticsLabel(RegExp('^[1-4]:')), findsNothing);
      expect(
        tester.getSemantics(find.bySemanticsLabel(RegExp('^Dictionary'))),
        isSemantics(isSelected: true, isButton: true),
      );
      handle.dispose();
    });

    testWidgets('reports the tapped tab', (tester) async {
      final selected = await pumpShell(tester, width: 390);

      await tester.tap(find.text('2:dictionary'));
      await tester.tap(find.text('4:conversation'));
      expect(selected, [1, 3]);
      // 48 dp targets.
      final size = tester.getSize(
        find
            .ancestor(
              of: find.text('2:dictionary'),
              matching: find.byWidgetPredicate((w) => w is InkResponse),
            )
            .first,
      );
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });

    testWidgets('fits 200 % text on a 320 dp phone', (tester) async {
      await pumpShell(tester, width: 320, height: 640, textScale: 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('restyles the sidebar on large screens', (tester) async {
      final selected = await pumpShell(tester, width: 1000);

      expect(find.byKey(const Key('terminal_navigation_rail')), findsOne);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('1:translate'), findsOneWidget);
      expect(find.byKey(const Key('terminal_nav_selected')), findsOneWidget);
      // A dashed edge instead of the hairline.
      final rule = tester.widget<TerminalRule>(find.byType(TerminalRule));
      expect(rule.axis, Axis.vertical);
      expect(find.byType(Hairline), findsNothing);
      expect(find.text('mozhi'), findsOneWidget);
      expect(find.bySemanticsLabel('Mozhi'), findsOneWidget);

      await tester.tap(find.text('3:proofread'));
      expect(selected, [2]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('puts the sidebar on the right in right-to-left languages', (
      tester,
    ) async {
      await pumpShell(tester, width: 1000, locale: const Locale('ar'));

      final rail = tester.getRect(
        find.byKey(const Key('terminal_navigation_rail')),
      );
      expect(rail.right, 1000);
      expect(tester.takeException(), isNull);
    });

    testWidgets('names History and Settings [h] and [s]', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpShell(tester, width: 390);

      expect(find.text('[h]'), findsOneWidget);
      expect(find.text('[s]'), findsOneWidget);
      expect(find.byIcon(Icons.history), findsNothing);
      expect(
        tester.getSemantics(find.byKey(TopLevelActions.historyKey)),
        isSemantics(label: 'History', isButton: true, hasTapAction: true),
      );
      expect(
        find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Settings'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'\[')), findsNothing);
      final size = tester.getSize(find.byKey(TopLevelActions.settingsKey));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      handle.dispose();
    });
  });
}
