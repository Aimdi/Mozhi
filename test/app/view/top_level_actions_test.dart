import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../../helpers/helpers.dart';
import '../../settings/view/helpers.dart' show createSettingsCubit;

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

    /// The location History was last opened at.
    Uri? historyUri;

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
          builder: (context, state) {
            historyUri = state.uri;
            return const _TopLevelPage('History page');
          },
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (context, state) => const _TopLevelPage('Settings page'),
        ),
      ],
    );

    setUp(() => historyUri = null);

    Future<void> pumpRouter(
      WidgetTester tester, {
      String initialLocation = AppRoutes.translate,
      SettingsCubit? settings,
    }) async {
      createRouter(initialLocation);
      addTearDown(router.dispose);
      final app = MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      );
      await tester.pumpWidget(
        settings == null
            ? app
            : BlocProvider<SettingsCubit>.value(value: settings, child: app),
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

      for (final key in [
        TopLevelActions.historyKey,
        TopLevelActions.settingsKey,
      ]) {
        final size = tester.getSize(find.byKey(key));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      // History is named by its icon: its tooltip says more (below).
      expect(
        tester.getSemantics(find.byKey(TopLevelActions.historyKey)),
        isSemantics(label: 'History', isButton: true),
      );
      final settings = find.byKey(TopLevelActions.settingsKey);
      expect(tester.widget<IconButton>(settings).tooltip, 'Settings');
      expect(
        tester.getSemantics(settings),
        isSemantics(tooltip: 'Settings', isButton: true),
      );
      expect(find.byIcon(Icons.history), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    group('a long press on History', () {
      testWidgets('opens it on the Favorites tab', (tester) async {
        await pumpRouter(tester);

        await tester.longPress(find.byKey(TopLevelActions.historyKey));
        await settle(tester);
        expect(find.text('History page'), findsOneWidget);
        expect(historyUri.toString(), '/history?tab=favorites');
        // Pushed above the tab: back returns to it.
        await tester.tap(find.byType(BackButton));
        await settle(tester);
        expect(location(), AppRoutes.translate);
      });

      group('vibrates', () {
        late List<String> haptics;

        setUp(() {
          haptics = [];
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                if (call.method.startsWith('HapticFeedback')) {
                  haptics.add(call.method);
                }
                return null;
              });
        });

        tearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );

        for (final enabled in [true, false]) {
          testWidgets(
            'only with haptic feedback on (${enabled ? 'on' : 'off'})',
            (tester) async {
              await pumpRouter(
                tester,
                settings: createSettingsCubit(
                  AppSettings(hapticFeedback: enabled),
                ),
              );

              await tester.longPress(find.byKey(TopLevelActions.historyKey));
              await settle(tester);

              expect(historyUri.toString(), '/history?tab=favorites');
              expect(haptics, enabled ? ['HapticFeedback.vibrate'] : isEmpty);
            },
          );
        }
      });

      testWidgets('is announced by screen readers', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpRouter(tester);
        expect(
          tester.getSemantics(find.byKey(TopLevelActions.historyKey)),
          isSemantics(
            label: 'History',
            isButton: true,
            hasTapAction: true,
            hasLongPressAction: true,
            hasFocusAction: true,
            isFocusable: true,
            hasEnabledState: true,
            isEnabled: true,
            onLongPressHint: 'Open favorites',
          ),
        );
        handle.dispose();
      });

      testWidgets('is in the tooltip shown when pointing at the button', (
        tester,
      ) async {
        await pumpRouter(tester);
        const tooltip = 'History\nLong-press to open favorites';
        expect(find.text(tooltip), findsNothing);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(find.byKey(TopLevelActions.historyKey)),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(find.text(tooltip), findsOneWidget);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
      });

      testWidgets('shows no tooltip on a touch screen', (tester) async {
        await pumpRouter(tester);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(TopLevelActions.historyKey)),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.text('History\nLong-press to open favorites'),
          findsNothing,
        );
        await gesture.up();
        await settle(tester);
        expect(historyUri.toString(), '/history?tab=favorites');
      });
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
        // History opens on the tab shown last.
        expect(
          historyUri?.toString(),
          title == 'History page' ? '/history' : null,
        );
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

    Future<void> pumpAt(
      WidgetTester tester,
      String location, {
      AppSettings? settings,
    }) async {
      router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: AppRoutes.translate,
            builder: (context, state) => const Scaffold(body: Text('Tab')),
          ),
          GoRoute(
            path: AppRoutes.dictionary,
            builder: (context, state) =>
                const Scaffold(body: Text('Dictionary tab')),
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
      addTearDown(router.dispose);
      final app = MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      );
      await tester.pumpWidget(
        settings == null
            ? app
            : BlocProvider<SettingsCubit>.value(
                value: createSettingsCubit(settings),
                child: app,
              ),
      );
      await tester.pump();
    }

    const dictionaryFirst = AppSettings(
      tabOrder: [
        AppTab.dictionary,
        AppTab.translate,
        AppTab.proofread,
        AppTab.conversation,
      ],
    );

    for (final page in [AppRoutes.history, AppRoutes.settings]) {
      testWidgets('$page has a back arrow to the first tab', (tester) async {
        await pumpAt(tester, page, settings: dictionaryFirst);

        await tester.tap(find.byKey(const Key('top_level_back')));
        await tester.pumpAndSettle();

        expect(find.text('Dictionary tab'), findsOneWidget);
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          AppRoutes.dictionary,
        );
      });

      testWidgets('$page goes to the first tab on system back', (tester) async {
        await pumpAt(tester, page, settings: dictionaryFirst);

        final handled = await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        expect(handled, isTrue);
        expect(find.text('Dictionary tab'), findsOneWidget);
      });
    }

    testWidgets('goes to the translate tab when it comes first', (
      tester,
    ) async {
      await pumpAt(tester, AppRoutes.history, settings: const AppSettings());

      await tester.tap(find.byKey(const Key('top_level_back')));
      await tester.pumpAndSettle();

      expect(find.text('Tab'), findsOneWidget);
    });

    testWidgets('without settings has a back arrow to the translate tab', (
      tester,
    ) async {
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

    testWidgets('without settings goes to the translate tab on system back', (
      tester,
    ) async {
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
