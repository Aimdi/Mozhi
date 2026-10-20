import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/l10n/l10n.dart';

import '../../helpers/helpers.dart';

/// Longer than any page transition.
const _transition = Duration(seconds: 1);

/// A page like History and Settings: its back arrow comes from
/// [topLevelBackButton], [TopLevelPageScope] handles system back.
class _TopLevelPage extends StatelessWidget {
  const new(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => TopLevelPageScope(
    child: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          leading: topLevelBackButton(context),
          title: Text(title),
        ),
      ),
    ),
  );
}

void main() {
  group('TopLevelActions', () {
    late GoRouter router;

    GoRouter createRouter(String initialLocation) => router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: AppRoutes.translate,
          builder: (context, state) => Scaffold(
            appBar: AppBar(
              title: const Text('Tab'),
              actions: const [TopLevelActions()],
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.history,
          builder: (context, state) => const _TopLevelPage('History page'),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (context, state) => const _TopLevelPage('Settings page'),
        ),
      ],
    );

    Future<void> pumpRouter(
      WidgetTester tester, {
      String initialLocation = AppRoutes.translate,
    }) async {
      createRouter(initialLocation);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(_transition);
    }

    String location() =>
        router.routerDelegate.currentConfiguration.uri.toString();

    testWidgets('are named 48 dp icon buttons', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRouter(tester);

      for (final (key, label) in [
        (TopLevelActions.historyKey, 'History'),
        (TopLevelActions.settingsKey, 'Settings'),
      ]) {
        final button = find.byKey(key);
        expect(tester.widget<IconButton>(button).tooltip, label);
        final size = tester.getSize(button);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(button),
          isSemantics(tooltip: label, isButton: true),
        );
      }
      expect(find.byIcon(Icons.history), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      handle.dispose();
    });

    for (final (key, title) in [
      (TopLevelActions.historyKey, 'History page'),
      (TopLevelActions.settingsKey, 'Settings page'),
    ]) {
      testWidgets('push "$title" above the page; back returns', (tester) async {
        await pumpRouter(tester);

        await tester.tap(find.byKey(key));
        await settle(tester);
        expect(find.text(title), findsOneWidget);
        // The app bar's own back button: there is a page below.
        expect(find.byKey(const Key('top_level_back')), findsNothing);

        await tester.tap(find.byType(BackButton));
        await settle(tester);
        expect(find.text(title), findsNothing);
        expect(find.text('Tab'), findsOneWidget);
        expect(location(), AppRoutes.translate);
      });
    }
  });

  group('a page opened on its own', () {
    late GoRouter router;

    Future<void> pumpAt(WidgetTester tester, String location) async {
      router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: AppRoutes.translate,
            builder: (context, state) => const Scaffold(body: Text('Tab')),
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const _TopLevelPage('Settings page'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.pump();
    }

    testWidgets('has a back arrow to the translate tab', (tester) async {
      await pumpAt(tester, AppRoutes.settings);

      final back = find.byKey(const Key('top_level_back'));
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();

      expect(find.text('Tab'), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        AppRoutes.translate,
      );
    });

    testWidgets('goes to the translate tab on system back', (tester) async {
      await pumpAt(tester, AppRoutes.settings);

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(find.text('Tab'), findsOneWidget);
    });
  });

  testWidgets('without a router the app bar keeps its own leading', (
    tester,
  ) async {
    await tester.pumpApp(const _TopLevelPage('Settings page'));

    expect(find.text('Settings page'), findsOneWidget);
    expect(find.byKey(const Key('top_level_back')), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    // System back is not intercepted without a router either.
    expect(await tester.binding.handlePopRoute(), isFalse);
  });
}
