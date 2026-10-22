import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/sync/view/sync_setup_page.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_webdav_server.dart';
import '../helpers/sync_harness.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
}

/// The setup page opened from a button, as the settings open it.
Future<void> _open(WidgetTester tester, SyncHarness harness) async {
  tester.view
    ..physicalSize = const Size(800, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpApp(
    harness.wrap(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSyncSetup(context, harness.service),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

Future<void> _fillConnection(
  WidgetTester tester, {
  String server = 'cloud.example.org/dav',
  String password = 'app-password',
}) async {
  await _type(tester, 'sync_server', server);
  await _type(tester, 'sync_user', 'alice');
  await _type(tester, 'sync_password', password);
}

Future<void> _test(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('sync_test')));
  await _settle(tester);
}

void main() {
  test('serverOf adds https and refuses plain http to public servers', () {
    expect(
      SyncAddress.server('cloud.example.org/dav').toString(),
      'https://cloud.example.org/dav',
    );
    expect(
      SyncAddress.server(' http://192.168.1.4:8080/ ').toString(),
      'http://192.168.1.4:8080/',
    );
    expect(SyncAddress.server('http://cloud.example.org'), isNull);
    expect(SyncAddress.server('ftp://cloud.example.org'), isNull);
    expect(SyncAddress.server(''), isNull);
    expect(SyncAddress.server('https://'), isNull);
    expect(SyncAddress.folder(' /Apps// Mozhi /'), 'Apps/Mozhi');
  });

  testWidgets('asks for what is missing before testing', (tester) async {
    final harness = SyncHarness();
    await _open(tester, harness);
    await tester.tap(find.byKey(const Key('sync_test')));
    await tester.pump();
    expect(find.text('Required'), findsNWidgets(3));
    await _type(tester, 'sync_server', 'http://cloud.example.org');
    expect(find.textContaining('starts with https://'), findsOneWidget);
    expect(harness.server.requests, isEmpty);
  });

  testWidgets('shows why the test failed, and tests again', (tester) async {
    final harness = SyncHarness();
    await _open(tester, harness);
    await _fillConnection(tester, password: 'wrong');
    await _test(tester);
    expect(
      find.text("The server didn't accept the user name or app password."),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sync_passphrase')), findsNothing);
    await _type(tester, 'sync_password', 'app-password');
    expect(
      find.text("The server didn't accept the user name or app password."),
      findsNothing,
    );
    await _test(tester);
    expect(find.byKey(const Key('sync_passphrase')), findsOneWidget);
  });

  testWidgets('the first device chooses a passphrase', (tester) async {
    final harness = SyncHarness();
    await _open(tester, harness);
    await _fillConnection(tester);
    await _test(tester);
    expect(find.textContaining('The folder will be created'), findsOneWidget);
    expect(find.byKey(const Key('sync_passphrase_repeat')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('sync_turn_on')));
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await tester.pump();
    expect(find.text('Required'), findsOneWidget);
    await _type(tester, 'sync_passphrase', 'short');
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await tester.pump();
    expect(find.text('Use at least 8 characters'), findsWidgets);
    await _type(tester, 'sync_passphrase', 'four random long words');
    expect(find.textContaining('Passphrase strength'), findsNothing);
    await _type(tester, 'sync_passphrase_repeat', 'four random long word');
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await tester.pump();
    expect(find.text("The passphrases don't match"), findsOneWidget);
    await _type(tester, 'sync_passphrase_repeat', 'four random long words');
    // Presets are left out, the settings stay out, Wi-Fi only.
    await tester.tap(find.byKey(const Key('sync_section_presets')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('sync_wifi_only')));
    await tester.tap(find.byKey(const Key('sync_wifi_only')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('sync_turn_on')));
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(find.byType(SyncSetupPage), findsNothing);
    expect(find.text('Sync is on'), findsOneWidget);
    final config = harness.service.state.config!;
    expect(config.server.toString(), 'https://cloud.example.org/dav');
    expect(config.folder, 'Mozhi');
    expect(config.excludedSections, {'settings', 'presets'});
    expect(config.wifiOnly, isTrue);
    expect(harness.server.files, contains(syncFilePath));
  });

  testWidgets('a second device enters the passphrase of the first', (
    tester,
  ) async {
    final server = FakeWebDavServer();
    final first = SyncHarness(server: server);
    await tester.runAsync(first.setUp);
    final harness = SyncHarness(server: server);
    await _open(tester, harness);
    await _fillConnection(tester);
    await _test(tester);
    expect(find.textContaining('Another device already syncs'), findsOneWidget);
    expect(find.byKey(const Key('sync_passphrase_repeat')), findsNothing);
    expect(find.textContaining('nothing is replaced'), findsOneWidget);
    await _type(tester, 'sync_passphrase', 'not the passphrase');
    await tester.ensureVisible(find.byKey(const Key('sync_turn_on')));
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await _settle(tester);
    expect(
      find.text("That passphrase doesn't open the synced data."),
      findsOneWidget,
    );
    expect(harness.service.state.isSetUp, isFalse);
    await _type(tester, 'sync_passphrase', 'correct horse battery');
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Sync is on'), findsOneWidget);
    expect(harness.service.state.unlocked, isTrue);
  });

  testWidgets('a failed first sync is shown above the button', (tester) async {
    final harness = SyncHarness();
    await _open(tester, harness);
    await _fillConnection(tester);
    await _test(tester);
    harness.server.intercept = (request) =>
        request.method == 'PUT' ? http.Response('', 507) : null;
    for (final key in ['sync_passphrase', 'sync_passphrase_repeat']) {
      await _type(tester, key, 'four random long words');
    }
    await tester.ensureVisible(find.byKey(const Key('sync_turn_on')));
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await _settle(tester);
    expect(find.text('Your storage on the server is full.'), findsOneWidget);
    expect(find.byType(SyncSetupPage), findsOneWidget);
  });

  testWidgets('an empty folder, secrets, and the hidden password', (
    tester,
  ) async {
    final harness = SyncHarness(
      server: FakeWebDavServer(folders: {'/dav/', '/dav/Mozhi/'}),
    );
    await _open(tester, harness);
    await _fillConnection(tester);
    final password = find.descendant(
      of: find.byKey(const Key('sync_password')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(password).obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(tester.widget<EditableText>(password).obscureText, isFalse);
    await _test(tester);
    expect(find.textContaining('Nothing is synced here yet'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('sync_section_settings')));
    await tester.tap(find.byKey(const Key('sync_section_settings')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sync_include_secrets')));
    await tester.pump();
    for (final key in ['sync_passphrase', 'sync_passphrase_repeat']) {
      await _type(tester, key, 'four random long words');
    }
    final gate = Completer<void>();
    harness.server.intercept = (request) async {
      if (request.method == 'PUT') await gate.future;
      return null;
    };
    await tester.ensureVisible(find.byKey(const Key('sync_turn_on')));
    await tester.tap(find.byKey(const Key('sync_turn_on')));
    await _settle(tester);
    expect(find.text('Turning on sync…'), findsOneWidget);
    gate.complete();
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(harness.service.state.config!.syncsSecrets, isTrue);
  });

  testWidgets('shows the test running', (tester) async {
    final harness = SyncHarness();
    await _open(tester, harness);
    await _fillConnection(tester);
    final gate = Completer<void>();
    harness.server.intercept = (request) async {
      await gate.future;
      return null;
    };
    await tester.tap(find.byKey(const Key('sync_test')));
    await tester.pump();
    expect(find.text('Testing the connection…'), findsOneWidget);
    gate.complete();
    await _settle(tester);
  });

  testWidgets('submitting the folder field tests the connection', (
    tester,
  ) async {
    final harness = SyncHarness();
    await _open(tester, harness);
    await _fillConnection(tester);
    await _type(tester, 'sync_folder', 'Apps/Mozhi');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(find.byKey(const Key('sync_passphrase')), findsOneWidget);
  });
}
