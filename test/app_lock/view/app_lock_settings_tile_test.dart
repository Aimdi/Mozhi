import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/app_lock.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/models/settings_category.dart';
import 'package:mozhi/settings/view/settings_search_index.dart';
import 'package:mozhi/settings/view/widgets/choice_dialog.dart';
import 'package:mozhi/settings/view/widgets/privacy_settings_section.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';

import '../../settings/view/helpers.dart';
import '../helpers/fake_app_lock_platform.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(AppLockTimeout.off);
  });

  late FakeAppLockPlatform platform;
  late AppLockController lock;
  late MockSettingsCubit settings;

  setUp(() {
    platform = FakeAppLockPlatform(unlocked: true);
    lock = AppLockController(platform: platform);
    settings = createSettingsCubit();
  });

  tearDown(() => lock.dispose());

  Future<void> pump(
    WidgetTester tester, {
    AppLockTimeout timeout = AppLockTimeout.off,
    bool provide = true,
  }) async {
    when(() => settings.state).thenReturn(AppSettings(appLock: timeout));
    final tile = Scaffold(
      body: ListView(children: [AppLockSettingsTile(timeout: timeout)]),
    );
    await tester.pumpView(
      provide
          ? RepositoryProvider<AppLock>.value(value: lock, child: tile)
          : tile,
      settings: settings,
    );
    await tester.pump();
  }

  ListTile row(WidgetTester tester) =>
      tester.widget<ListTile>(find.byKey(const Key('settings_app_lock')));

  Future<void> choose(WidgetTester tester, String option) async {
    await tester.tap(find.byKey(const Key('settings_app_lock')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.tap(find.byKey(ChoiceDialog.saveKey));
    await tester.pumpAndSettle();
  }

  group('appLockTimeoutLabel', () {
    testWidgets('names every timeout', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpView(
        Builder(
          builder: (context) {
            l10n = context.l10n;
            return const SizedBox.shrink();
          },
        ),
      );

      expect(
        [for (final t in AppLockTimeout.values) appLockTimeoutLabel(l10n, t)],
        [
          'Off',
          'Immediately',
          'After 1 minute',
          'After 5 minutes',
          'After 15 minutes',
        ],
      );
    });
  });

  group(AppLockSettingsTile, () {
    testWidgets('shows the setting when the phone has a screen lock', (
      tester,
    ) async {
      await pump(tester, timeout: AppLockTimeout.after5Minutes);

      expect(find.text('App lock'), findsOneWidget);
      expect(find.text('After 5 minutes'), findsOneWidget);
      expect(row(tester).enabled, isTrue);
    });

    testWidgets('turns the lock on after one successful unlock', (
      tester,
    ) async {
      await pump(tester);

      await choose(tester, 'Immediately');

      expect(platform.prompts, hasLength(1));
      verify(() => settings.setAppLock(AppLockTimeout.immediately)).called(1);
    });

    testWidgets('stays off when the unlock is cancelled', (tester) async {
      platform.promptResult = AppLockPromptResult.cancelled;
      await pump(tester);

      await choose(tester, 'After 1 minute');

      verifyNever(() => settings.setAppLock(any()));
      expect(
        find.text('App lock is still off: Mozhi could not confirm it is you.'),
        findsOneWidget,
      );
    });

    testWidgets('changes the time without asking', (tester) async {
      await pump(tester, timeout: AppLockTimeout.immediately);

      await choose(tester, 'After 15 minutes');

      expect(platform.prompts, isEmpty);
      verify(() => settings.setAppLock(AppLockTimeout.after15Minutes))
          .called(1);
    });

    testWidgets('turns the lock off without asking', (tester) async {
      await pump(tester, timeout: AppLockTimeout.after1Minute);

      await choose(tester, 'Off');

      expect(platform.prompts, isEmpty);
      verify(() => settings.setAppLock(AppLockTimeout.off)).called(1);
    });

    testWidgets('explains the choice', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('settings_app_lock')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Recents shows no preview'), findsOneWidget);
      expect(find.byType(RadioListTile<AppLockTimeout>), findsNWidgets(5));
    });

    testWidgets('changes nothing for the same choice or Cancel', (
      tester,
    ) async {
      await pump(tester);

      await choose(tester, 'Off');
      await tester.tap(find.byKey(const Key('settings_app_lock')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(() => settings.setAppLock(any()));
      expect(platform.prompts, isEmpty);
    });

    testWidgets('is off with the reason when the phone has no screen lock', (
      tester,
    ) async {
      platform.secure = false;
      await pump(tester);

      expect(
        find.text(
          'Set a screen lock (PIN, pattern or password) on your phone first',
        ),
        findsOneWidget,
      );
      expect(row(tester).enabled, isFalse);
      expect(row(tester).onTap, isNull);
    });

    testWidgets('looks again when the app comes back', (tester) async {
      platform.secure = false;
      await pump(tester);
      expect(row(tester).enabled, isFalse);

      // The user set a screen lock in the phone's settings.
      platform.secure = true;
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(row(tester).enabled, isTrue);
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('is off without an app lock', (tester) async {
      await pump(tester, provide: false);

      expect(row(tester).enabled, isFalse);
      expect(find.textContaining('Set a screen lock'), findsOneWidget);
    });

    testWidgets('says where it is available on other platforms', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pump(tester);

      expect(find.text('Only in the Android app'), findsOneWidget);
      expect(row(tester).enabled, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('waits for the answer with the current choice', (tester) async {
      platform.holdSessions = true;
      await pump(tester, timeout: AppLockTimeout.immediately);

      expect(find.text('Immediately'), findsOneWidget);
      expect(row(tester).enabled, isFalse);
    });

    testWidgets('follows a new app lock', (tester) async {
      await pump(tester);
      platform.secure = false;
      final other = AppLockController(platform: platform);
      addTearDown(other.dispose);

      await tester.pumpView(
        RepositoryProvider<AppLock>.value(
          value: other,
          child: const Scaffold(
            body: AppLockSettingsTile(timeout: AppLockTimeout.off),
          ),
        ),
        settings: settings,
      );
      await tester.pump();

      expect(row(tester).enabled, isFalse);
    });
  });

  testWidgets('is a row of Privacy & data', (tester) async {
    tester.setScreenSize(const Size(800, 3000));
    when(() => settings.state).thenReturn(const AppSettings());
    await tester.pumpView(
      RepositoryProvider<AppLock>.value(
        value: lock,
        child: Scaffold(
          body: ListView(
            children: const [PrivacySettingsSection(settings: AppSettings())],
          ),
        ),
      ),
      settings: settings,
      history: createHistoryCubit(),
    );
    await tester.pump();

    expect(find.byType(AppLockSettingsTile), findsOneWidget);
    expect(PrivacyAnchors.appLock, AppLockSettingsTile.anchor);
  });

  testWidgets('is found by the settings search', (tester) async {
    late List<SettingsSearchEntry> entries;
    await tester.pumpView(
      Builder(
        builder: (context) {
          entries = [
            for (final entry in settingsSearchIndex(
              context,
              const AppSettings(appLock: AppLockTimeout.after1Minute),
            ))
              if (entry.anchor == AppLockSettingsTile.anchor) entry,
          ];
          return const SizedBox.shrink();
        },
      ),
    );

    final entry = entries.single;
    expect(entry.category, SettingsCategory.privacy);
    expect(entry.title, 'App lock');
    expect(entry.subtitle, 'After 1 minute');
    expect(entry.keywords.join(' '), contains('fingerprint'));
    expect(entry.keywords, contains('Immediately'));
  });
}
