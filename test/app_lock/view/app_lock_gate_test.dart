import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/src/scheduler/ticker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app_lock/app_lock.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../helpers/fake_app_lock_platform.dart';

/// A screen with state: a counter, a text field, and whether it was
/// disposed.
class _Page extends StatefulWidget {
  const new();

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with SingleTickerProviderStateMixin {
  static int disposed = 0;
  int count = 0;
  final focus = FocusNode();
  late final Ticker ticker = createTicker((_) {})..start();

  @override
  void dispose() {
    disposed++;
    ticker.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text('Count: $count'),
          SizedBox(
            width: 400,
            height: 300,
            child: ElevatedButton(
              key: const Key('page_more'),
              onPressed: () => setState(() => count++),
              child: const Text('Secret more'),
            ),
          ),
          TextField(key: const Key('page_field'), focusNode: focus),
        ],
      ),
    );
  }
}

/// Counts how often the app's content is built.
class _Content extends StatelessWidget {
  const new();

  static int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return const Scaffold(body: Center(child: Text('Secret history')));
  }
}

void main() {
  late FakeAppLockPlatform platform;

  setUp(() {
    platform = FakeAppLockPlatform();
    _Content.builds = 0;
  });

  AppLockController create({
    AppLockTimeout timeout = AppLockTimeout.immediately,
  }) => AppLockController(platform: platform, timeout: timeout);

  Future<void> pumpGate(
    WidgetTester tester,
    AppLockController lock, {
    bool compact = false,
    bool blocking = true,
    VoidCallback? onClose,
    Widget child = const _Content(),
    ThemeData? theme,
  }) async {
    addTearDown(lock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppLockGate(
          lock: lock,
          compact: compact,
          blocking: blocking,
          onClose: onClose,
          child: child,
        ),
      ),
    );
  }

  Future<void> goTo(WidgetTester tester, List<AppLifecycleState> states) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  /// Leaves the app; due timers run (no frames while it is away).
  Future<void> leave(WidgetTester tester) async {
    await goTo(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump(Duration.zero);
  }

  /// Comes back up to the first frame, before the window is resumed.
  Future<void> show(WidgetTester tester) => goTo(tester, const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
  ]);

  /// Comes back and resumes (the prompt opens now).
  Future<void> comeBack(WidgetTester tester) async {
    await show(tester);
    await goTo(tester, const [AppLifecycleState.resumed]);
    await tester.pump();
  }

  group(AppLockGate, () {
    testWidgets('shows the content when the lock is off', (tester) async {
      await pumpGate(tester, create(timeout: AppLockTimeout.off));

      expect(find.text('Secret history'), findsOneWidget);
      expect(find.byType(AppLockScreen), findsNothing);
      expect(platform.prompts, isEmpty);
    });

    testWidgets('builds nothing of the app while it finds out', (tester) async {
      platform.holdSessions = true;
      await pumpGate(tester, create());

      expect(find.byKey(const Key('app_lock_checking')), findsOneWidget);
      expect(_Content.builds, 0);
      expect(platform.prompts, isEmpty);
    });

    testWidgets('shows the lock screen instead of the app, and prompts '
        'once by itself', (tester) async {
      platform.holdPrompt = Completer();
      await pumpGate(tester, create());
      await tester.pump();

      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(find.text('Mozhi is locked'), findsOneWidget);
      expect(find.text('Mozhi'), findsOneWidget);
      expect(_Content.builds, 0, reason: 'nothing built before an unlock');
      expect(platform.prompts, hasLength(1));
      // The button waits while the prompt shows.
      expect(
        tester
            .widget<ButtonStyleButton>(find.byKey(AppLockScreen.unlockKey))
            .onPressed,
        isNull,
      );

      platform.holdPrompt!.complete(AppLockPromptResult.success);
      await tester.pump();
      await tester.pump();

      expect(find.text('Secret history'), findsOneWidget);
      expect(find.byType(AppLockScreen), findsNothing);
    });

    testWidgets('keeps the lock screen after a cancelled prompt, with a '
        'button to try again', (tester) async {
      platform.promptResult = AppLockPromptResult.cancelled;
      await pumpGate(tester, create());
      await tester.pump();
      await tester.pump();

      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(find.text('Not unlocked. Tap Unlock to try again.'), findsOne);
      expect(platform.prompts, hasLength(1), reason: 'no prompt loop');
      expect(_Content.builds, 0);

      platform.promptResult = AppLockPromptResult.success;
      await tester.tap(find.byKey(AppLockScreen.unlockKey));
      await tester.pump();
      await tester.pump();

      expect(platform.prompts, hasLength(2));
      expect(find.text('Secret history'), findsOneWidget);
    });

    testWidgets('gives the prompt texts in the app language', (tester) async {
      final lock = create(timeout: AppLockTimeout.off);
      await pumpGate(tester, lock);

      expect(
        lock.promptTexts,
        const AppLockPromptTexts(
          title: 'Unlock Mozhi',
          subtitle: 'Use your fingerprint, face or screen lock',
          fallback: 'Use PIN, pattern or password',
        ),
      );
      expect(lock.confirmTexts?.title, 'Turn on app lock');
    });

    testWidgets('locks again when the app comes back, and prompts once', (
      tester,
    ) async {
      platform.unlocked = true;
      await pumpGate(tester, create());
      await tester.pump();
      expect(find.text('Secret history'), findsOneWidget);
      expect(platform.prompts, isEmpty, reason: 'unlocked already');

      final lock = tester.widget<AppLockGate>(find.byType(AppLockGate)).lock;
      platform.leave(Duration.zero);
      await leave(tester);
      expect(lock.isLocked, isTrue, reason: 'locked while away');
      expect(platform.prompts, isEmpty, reason: 'no prompt while away');

      platform.comeBack();
      await show(tester);
      // The first frame back is the lock screen.
      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(find.text('Secret history'), findsNothing);
      expect(platform.prompts, isEmpty);

      await goTo(tester, const [AppLifecycleState.resumed]);
      await tester.pump();

      expect(platform.prompts, hasLength(1));
      expect(find.text('Secret history'), findsOneWidget);
      expect(_Content.builds, 1, reason: 'kept, not built anew');
    });

    testWidgets('stays unlocked for a short trip with a longer timeout', (
      tester,
    ) async {
      platform.unlocked = true;
      await pumpGate(tester, create(timeout: AppLockTimeout.after5Minutes));
      await tester.pump();
      final builds = _Content.builds;

      platform.leave(const Duration(seconds: 10));
      await leave(tester);
      platform.comeBack();
      await comeBack(tester);
      await tester.pump();

      expect(find.text('Secret history'), findsOneWidget);
      expect(_Content.builds, builds, reason: 'the content was kept');
      expect(platform.prompts, isEmpty);
    });

    testWidgets('does not prompt while the app is in the background', (
      tester,
    ) async {
      platform.holdSessions = true;
      await pumpGate(tester, create());
      await leave(tester);

      platform.pendingSessions.single.complete(platform.current);
      await tester.pump(Duration.zero);

      expect(
        tester.widget<AppLockGate>(find.byType(AppLockGate)).lock.isLocked,
        isTrue,
      );
      expect(platform.prompts, isEmpty);

      platform.holdSessions = false;
      await show(tester);
      expect(find.byType(AppLockScreen), findsOneWidget);
      expect(platform.prompts, isEmpty);
      await comeBack(tester);
      expect(platform.prompts, hasLength(1));
    });

    testWidgets('is announced to screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      platform.promptResult = AppLockPromptResult.cancelled;
      await pumpGate(tester, create());
      await tester.pump();
      await tester.pump();

      expect(
        tester.getSemantics(find.text('Mozhi is locked')),
        isSemantics(isHeader: true, label: 'Mozhi is locked'),
      );
      expect(find.bySemanticsLabel('Unlock'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(AppLockScreen.unlockKey)).height,
        greaterThanOrEqualTo(48),
      );
      handle.dispose();
    });

    testWidgets('fits a small phone at 200% text in the dark', (tester) async {
      tester.view
        ..physicalSize = const Size(320, 480)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      platform.promptResult = AppLockPromptResult.cancelled;
      final lock = create();
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AppLockGate(lock: lock, child: const _Content()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(AppLockScreen), findsOneWidget);
    });

    group('once unlocked', () {
      Future<_PageState> pumpPage(WidgetTester tester) async {
        _PageState.disposed = 0;
        platform.unlocked = true;
        await pumpGate(tester, create(), child: const _Page());
        await tester.pump();
        return tester.state<_PageState>(find.byType(_Page));
      }

      Future<void> lockNow(WidgetTester tester) async {
        platform.leave(Duration.zero);
        await leave(tester);
        platform
          ..comeBack()
          ..promptResult = AppLockPromptResult.cancelled;
        await comeBack(tester);
        await tester.pump();
        expect(find.byType(AppLockScreen), findsOneWidget);
      }

      Future<void> unlockNow(WidgetTester tester) async {
        platform.promptResult = AppLockPromptResult.success;
        await tester.tap(find.byKey(AppLockScreen.unlockKey));
        await tester.pump();
        await tester.pump();
        expect(find.byType(AppLockScreen), findsNothing);
      }

      testWidgets('keeps the screens and their state while locked', (
        tester,
      ) async {
        final page = await pumpPage(tester);
        await tester.tap(find.byKey(const Key('page_more')));
        await tester.tap(find.byKey(const Key('page_more')));
        await tester.pump();

        await lockNow(tester);
        // Hidden, but alive.
        expect(find.text('Count: 2'), findsNothing);
        expect(find.text('Count: 2', skipOffstage: false), findsOneWidget);
        expect(_PageState.disposed, 0);
        expect(page.ticker.muted, isTrue, reason: 'animations stopped');

        await unlockNow(tester);
        expect(tester.state<_PageState>(find.byType(_Page)), same(page));
        expect(find.text('Count: 2'), findsOneWidget);
        expect(page.ticker.muted, isFalse);
        expect(_PageState.disposed, 0);
      });

      testWidgets('lets no touch through to them', (tester) async {
        final page = await pumpPage(tester);
        final button = tester.getCenter(find.byKey(const Key('page_more')));

        await lockNow(tester);
        await tester.tapAt(button);
        await tester.pump();
        expect(find.byKey(const Key('page_more')).hitTestable(), findsNothing);

        await unlockNow(tester);
        expect(page.count, 0);
      });

      testWidgets('keeps them out of the screen reader', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpPage(tester);
        expect(find.bySemanticsLabel('Secret more'), findsOneWidget);

        await lockNow(tester);

        expect(find.bySemanticsLabel('Secret more'), findsNothing);
        expect(find.bySemanticsLabel(RegExp('Count')), findsNothing);
        expect(find.bySemanticsLabel('Mozhi is locked'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('takes the keyboard focus and the keyboard away', (
        tester,
      ) async {
        final page = await pumpPage(tester);
        await tester.tap(find.byKey(const Key('page_field')));
        await tester.pump();
        expect(page.focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);

        await lockNow(tester);
        expect(page.focus.hasFocus, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);

        // Neither Tab nor a request brings it back while locked.
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(page.focus.hasFocus, isFalse);
        }
        page.focus.requestFocus();
        await tester.pump();
        expect(page.focus.hasFocus, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);

        await unlockNow(tester);
        page.focus.requestFocus();
        await tester.pump();
        expect(page.focus.hasFocus, isTrue);
      });

      testWidgets('shows no messages of the hidden screens', (tester) async {
        final page = await pumpPage(tester);
        await lockNow(tester);

        ScaffoldMessenger.of(page.context)
            .showSnackBar(const SnackBar(content: Text('Saved secret.docx')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.text('Saved secret.docx'), findsNothing);
      });
    });

    group('compact', () {
      testWidgets('shows a card with Close and Unlock above the other app', (
        tester,
      ) async {
        var closed = 0;
        platform.promptResult = AppLockPromptResult.cancelled;
        await pumpGate(
          tester,
          create(),
          compact: true,
          onClose: () => closed++,
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(AppLockCompactScreen), findsOneWidget);
        expect(find.byType(AppLockScreen), findsNothing);
        expect(
          find.text('Unlock Mozhi to translate the selected text.'),
          findsOne,
        );
        expect(find.text('Not unlocked. Tap Unlock to try again.'), findsOne);
        expect(_Content.builds, 0);

        await tester.tap(find.byKey(AppLockCompactScreen.closeKey));
        expect(closed, 1);

        // Around the card: the other app, which closes the window too.
        await tester.tapAt(const Offset(10, 10));
        expect(closed, 2);

        platform.promptResult = AppLockPromptResult.success;
        await tester.tap(find.byKey(AppLockScreen.unlockKey));
        await tester.pump();
        await tester.pump();
        expect(find.text('Secret history'), findsOneWidget);
      });

      testWidgets('is transparent while it finds out', (tester) async {
        platform.holdSessions = true;
        await pumpGate(tester, create(), compact: true);

        final blank = tester.widget<ColoredBox>(
          find.byKey(const Key('app_lock_checking')),
        );
        expect(blank.color, Colors.transparent);
      });

      testWidgets('works without a close action', (tester) async {
        platform.promptResult = AppLockPromptResult.cancelled;
        await pumpGate(tester, create(), compact: true);
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byKey(AppLockCompactScreen.closeKey));
        expect(find.byType(AppLockCompactScreen), findsOneWidget);
      });
    });

    testWidgets('lets a window that gates itself show its content', (
      tester,
    ) async {
      final lock = create();
      await pumpGate(tester, lock, blocking: false);
      await tester.pump();

      expect(lock.isLocked, isTrue);
      expect(find.text('Secret history'), findsOneWidget);
      expect(platform.prompts, isEmpty, reason: 'the window asks itself');

      // The lifecycle still reaches the lock.
      await leave(tester);
      await comeBack(tester);
      expect(lock.takeAutoPrompt(), isTrue);
    });

    testWidgets('follows a new lock', (tester) async {
      final first = create(timeout: AppLockTimeout.off);
      await pumpGate(tester, first);
      expect(find.text('Secret history'), findsOneWidget);

      platform.promptResult = AppLockPromptResult.cancelled;
      final second = create();
      addTearDown(second.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppLockGate(lock: second, child: const _Content()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(AppLockScreen), findsOneWidget);
    });

    testWidgets('above the router, keeps the pages and links of a '
        'locked app', (tester) async {
      platform.unlocked = true;
      final lock = create();
      addTearDown(lock.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: Text('Home')),
            routes: [
              GoRoute(
                path: 'detail',
                builder: (context, state) =>
                    const Scaffold(body: Text('Detail')),
              ),
              GoRoute(
                path: 'linked',
                builder: (context, state) =>
                    const Scaffold(body: Text('Linked')),
              ),
            ],
          ),
        ],
      );
      void keep() {}
      router.routeInformationProvider.addListener(keep);
      addTearDown(() {
        router.routeInformationProvider.removeListener(keep);
        router.dispose();
      });
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => AppLockGate(lock: lock, child: child!),
        ),
      );
      await tester.pump();
      unawaited(router.push<void>('/detail'));
      await tester.pumpAndSettle();
      expect(find.text('Detail'), findsOneWidget);

      platform.leave(Duration.zero);
      await leave(tester);
      platform.comeBack();
      await show(tester);
      expect(find.text('Detail'), findsNothing);
      expect(find.byType(AppLockScreen), findsOneWidget);

      await comeBack(tester);
      await tester.pumpAndSettle();

      expect(find.text('Detail'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);

      // A link that arrives while locked opens once unlocked.
      platform.leave(Duration.zero);
      await leave(tester);
      await tester.binding.handlePushRoute('/linked');
      platform.comeBack();
      await show(tester);
      expect(find.byType(AppLockScreen), findsOneWidget);
      await comeBack(tester);
      await tester.pumpAndSettle();

      expect(find.text('Linked'), findsOneWidget);
    });
  });
}
