import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/sync/view/sync_settings_section.dart';
import 'package:mozhi/sync/view/sync_setup_page.dart';
import 'package:mozhi/sync/view/widgets/sync_fields.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import '../../helpers/helpers.dart';
import '../helpers/sync_harness.dart';

Future<void> _pump(WidgetTester tester, SyncHarness harness) async {
  tester.view
    ..physicalSize = const Size(800, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpApp(
    harness.wrap(
      Scaffold(body: ListView(children: const [SyncSettingsSection()])),
    ),
  );
  await tester.runAsync(() => harness.service.load());
  await tester.pump();
}

/// Lets the service's real work (network, encryption) finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
}

void main() {
  testWidgets('shows nothing without a sync service', (tester) async {
    await tester.pumpApp(const SyncSettingsSection());
    expect(find.text('Sync'), findsNothing);
    expect(find.byType(SizedBox), findsWidgets);
  });

  testWidgets('offers to set sync up', (tester) async {
    final harness = SyncHarness();
    await _pump(tester, harness);
    expect(find.text('Sync'), findsOneWidget);
    expect(find.textContaining('end-to-end encrypted'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sync_set_up')));
    await tester.pumpAndSettle();
    expect(find.byType(SyncSetupPage), findsOneWidget);
  });

  testWidgets('is paused in Offline only', (tester) async {
    final harness = SyncHarness(mode: PrivacyMode.offlineOnly);
    await _pump(tester, harness);
    expect(find.byKey(const Key('sync_offline_only')), findsOneWidget);
    final tile = tester.widget<ListTile>(find.byKey(const Key('sync_set_up')));
    expect(tile.enabled, isFalse);
  });

  testWidgets('not synced yet, with a port, spinning still without '
      'animations', (tester) async {
    final harness = SyncHarness();
    harness.prefs.values['sync.v1'] =
        '{"server": "https://nas.local:5006/dav/", "username": "alice"}';
    await _pump(tester, harness);
    expect(find.text('Mozhi on nas.local:5006'), findsOneWidget);
    expect(find.text('Not synced yet'), findsOneWidget);
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SyncSpinner(),
        ),
      ),
    );
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
  });

  group('when set up', () {
    late SyncHarness harness;

    Future<void> setUpSync(WidgetTester tester) async {
      harness = SyncHarness();
      await tester.runAsync(harness.setUp);
      await _pump(tester, harness);
    }

    testWidgets('shows where it syncs and when it last did', (tester) async {
      await setUpSync(tester);
      expect(find.text('Mozhi on cloud.example.org'), findsOneWidget);
      expect(find.textContaining('Last synced'), findsOneWidget);
      expect(find.text('History and favorites, Presets'), findsOneWidget);
      expect(find.byKey(const Key('sync_unlock')), findsNothing);
    });

    testWidgets('Sync now says what happened', (tester) async {
      await setUpSync(tester);
      await tester.tap(find.byKey(const Key('sync_now')));
      await _settle(tester);
      expect(find.text('Everything is up to date'), findsOneWidget);
    });

    testWidgets('Sync now shows a failure', (tester) async {
      await setUpSync(tester);
      harness.server.intercept = (_) => http.Response('', 503);
      await tester.tap(find.byKey(const Key('sync_now')));
      await _settle(tester);
      expect(
        find.text('The server had a problem. Try again later.'),
        findsOneWidget,
      );
      expect(find.textContaining('Last sync failed'), findsOneWidget);
    });

    testWidgets('What to sync changes the sections', (tester) async {
      await setUpSync(tester);
      await tester.tap(find.byKey(const Key('sync_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync_section_presets')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_section_settings')));
      await tester.pump();
      expect(find.byKey(const Key('sync_include_secrets')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync_include_secrets')));
      await tester.pump();
      expect(
        find.textContaining('anyone who gets the sync file'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('sync_options_save')));
      await _settle(tester);
      final config = harness.service.state.config!;
      expect(config.excludedSections, {'presets'});
      expect(config.syncsSecrets, isTrue);
      expect(find.text('History and favorites, Settings'), findsOneWidget);
      await harness.service.dispose();
    });

    testWidgets('the last section stays chosen', (tester) async {
      await setUpSync(tester);
      await tester.tap(find.byKey(const Key('sync_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync_section_presets')));
      await tester.pump();
      final history = tester.widget<CheckboxListTile>(
        find.byKey(const Key('sync_section_history')),
      );
      expect(history.onChanged, isNull);
      expect(find.text('Choose at least one'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(harness.service.state.config!.excludedSections, {'settings'});
    });

    testWidgets('Wi-Fi only is saved', (tester) async {
      await setUpSync(tester);
      await tester.tap(find.byKey(const Key('sync_wifi_only')));
      await _settle(tester);
      expect(harness.service.state.config!.wifiOnly, isTrue);
      await harness.service.dispose();
    });

    testWidgets('changes the passphrase', (tester) async {
      await setUpSync(tester);
      await tester.tap(find.byKey(const Key('sync_change_passphrase')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync_new_passphrase_submit')));
      await tester.pump();
      expect(find.text('Use at least 8 characters'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('sync_new_passphrase')),
        'a much better passphrase',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('sync_new_passphrase_repeat')),
        'a much better passphrasf',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_new_passphrase_submit')));
      await tester.pump();
      expect(find.text("The passphrases don't match"), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('sync_new_passphrase_repeat')),
        'a much better passphrase',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_new_passphrase_submit')));
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Sync passphrase changed'), findsOneWidget);
    });

    testWidgets('a failed passphrase change stays in the dialog', (
      tester,
    ) async {
      await setUpSync(tester);
      harness.server.intercept = (request) =>
          request.method == 'PUT' ? http.Response('', 507) : null;
      await tester.tap(find.byKey(const Key('sync_change_passphrase')));
      await tester.pumpAndSettle();
      for (final field in [
        'sync_new_passphrase',
        'sync_new_passphrase_repeat',
      ]) {
        await tester.enterText(
          find.byKey(Key(field)),
          'four random long words',
        );
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('sync_new_passphrase_submit')));
      await _settle(tester);
      expect(find.text('Your storage on the server is full.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('turns sync off and deletes the file', (tester) async {
      await setUpSync(tester);
      await tester.tap(find.byKey(const Key('sync_turn_off')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync_turn_off_delete')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_turn_off_confirm')));
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Sync is off'), findsOneWidget);
      expect(find.byKey(const Key('sync_set_up')), findsOneWidget);
      expect(harness.server.files, isEmpty);
      expect(harness.secrets.values, isEmpty);
    });

    testWidgets('a failed delete keeps sync on', (tester) async {
      await setUpSync(tester);
      harness.server.intercept = (request) =>
          request.method == 'DELETE' ? http.Response('', 403) : null;
      await tester.tap(find.byKey(const Key('sync_turn_off')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sync_turn_off_delete')));
      await tester.tap(find.byKey(const Key('sync_turn_off_confirm')));
      await _settle(tester);
      expect(
        find.text('This account may not use that folder.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(harness.service.state.isSetUp, isTrue);
    });

    testWidgets('unlocks after the web app forgot the secrets', (tester) async {
      harness = SyncHarness();
      await tester.runAsync(harness.setUp);
      harness.secrets.values.clear();
      final fresh = SyncHarness(server: harness.server);
      fresh.prefs.values.addAll(harness.prefs.values);
      await _pump(tester, fresh);
      expect(find.byKey(const Key('sync_unlock')), findsOneWidget);
      final syncNow = tester.widget<ListTile>(
        find.byKey(const Key('sync_now')),
      );
      expect(syncNow.enabled, isFalse);
      await tester.tap(find.byKey(const Key('sync_unlock')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sync_unlock_password')),
        'app-password',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('sync_unlock_passphrase')),
        'wrong passphrase',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_unlock_submit')));
      await _settle(tester);
      expect(
        find.text("That passphrase doesn't open the synced data."),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('sync_unlock_passphrase')),
        'correct horse battery',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_unlock_submit')));
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync_unlock')), findsNothing);
      expect(fresh.service.state.unlocked, isTrue);
    });

    testWidgets('asks for a new passphrase or password', (tester) async {
      await setUpSync(tester);
      harness.server.intercept = (_) => http.Response('', 401);
      await tester.tap(find.byKey(const Key('sync_now')));
      await _settle(tester);
      expect(find.text('Enter the app password'), findsOneWidget);
      harness.server.intercept = null;
      await tester.tap(find.byKey(const Key('sync_unlock')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync_unlock_passphrase')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('sync_unlock_password')),
        'wrong',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_unlock_submit')));
      await _settle(tester);
      expect(
        find.text("The server didn't accept the user name or app password."),
        findsWidgets,
      );
      await tester.enterText(
        find.byKey(const Key('sync_unlock_password')),
        'app-password',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_unlock_submit')));
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Enter the app password'), findsNothing);

      // Another device changed the passphrase.
      final other = SyncHarness(server: harness.server);
      await tester.runAsync(() async {
        await other.setUp();
        await other.service.changePassphrase('the new long passphrase');
      });
      await tester.tap(find.byKey(const Key('sync_now')));
      await _settle(tester);
      expect(find.text('Enter the new passphrase'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync_unlock')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync_unlock_password')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('sync_unlock_passphrase')),
        'the new long passphrase',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sync_unlock_submit')));
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Enter the new passphrase'), findsNothing);
    });
  });
}
