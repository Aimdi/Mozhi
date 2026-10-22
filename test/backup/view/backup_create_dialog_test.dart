import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/data/backup_status_store.dart';
import 'package:mozhi/backup/view/backup_create_dialog.dart';
import 'package:mozhi/backup/view/backup_services.dart';
import 'package:mozhi/core/key_value_store.dart';

import '../../helpers/helpers.dart';
import '../helpers/backup_fakes.dart';

void main() {
  late BackupRegistry registry;
  late MemorySection history;
  late MemorySection settings;
  late FakeBackupFiles files;
  late MemoryStore prefs;
  bool? result;

  setUp(() {
    history = MemorySection('history', data: [1]);
    settings = MemorySection('settings', data: {'a': 1});
    registry = BackupRegistry(appVersion: () async => '1.0.0')
      ..register(history)
      ..register(MemorySection('presets', data: const <Object?>[]))
      ..register(MemorySection('glossaries', data: const <Object?>[]))
      ..register(settings)
      ..register(MemorySection('phrasebook'))
      ..register(MemorySection('practice'))
      ..register(MemorySection('future'));
    files = FakeBackupFiles();
    prefs = MemoryStore();
    BackupServices.files = files;
    BackupServices.codec = testCodec;
    result = null;
  });

  tearDown(() {
    BackupServices.files = const PlatformBackupFiles();
    BackupServices.codec = const BackupCodec();
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(400, 900),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BackupRegistry>.value(value: registry),
          RepositoryProvider<KeyValueStore>.value(value: prefs),
        ],
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async =>
                    result = await showBackupCreateDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> enterPassphrase(
    WidgetTester tester,
    String passphrase, {
    String? repeat,
  }) async {
    await tester.enterText(
      find.byKey(const Key('backup_passphrase')),
      passphrase,
    );
    await tester.enterText(
      find.byKey(const Key('backup_passphrase_repeat')),
      repeat ?? passphrase,
    );
    await tester.pump();
  }

  FilledButton createButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const Key('backup_create_action')),
  );

  testWidgets('lists every part, all included, and secrets off', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Back up your data'), findsOneWidget);
    for (final name in [
      'History and favorites',
      'Presets',
      'Glossaries',
      'Settings',
      'Phrasebook',
      'Practice progress',
      'future',
    ]) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(
      tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .every((tile) => tile.value!),
      isTrue,
    );
    final secrets = tester.widget<SwitchListTile>(
      find.byKey(const Key('backup_include_secrets')),
    );
    expect(secrets.value, isFalse);
    expect(find.byKey(const Key('backup_secrets_warning')), findsNothing);
    // Full screen on a phone.
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('warns when secrets are included', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const Key('backup_include_secrets')));
    await tester.pump();

    expect(find.byKey(const Key('backup_secrets_warning')), findsOneWidget);
    expect(find.textContaining('can use your API keys'), findsOneWidget);
  });

  testWidgets('needs a long enough passphrase, typed twice', (tester) async {
    await open(tester);
    expect(createButton(tester).onPressed, isNull);

    await enterPassphrase(tester, 'short');
    expect(find.text('Use at least 8 characters'), findsOneWidget);
    expect(createButton(tester).onPressed, isNull);

    await enterPassphrase(
      tester,
      'correct horse battery staple',
      repeat: 'correct horse',
    );
    expect(find.text("The passphrases don't match"), findsOneWidget);
    expect(createButton(tester).onPressed, isNull);

    await enterPassphrase(tester, 'correct horse battery staple');
    expect(find.text('Strong'), findsOneWidget);
    expect(find.text("The passphrases don't match"), findsNothing);
    expect(createButton(tester).onPressed, isNotNull);
  });

  testWidgets('nothing included: no backup', (tester) async {
    await open(tester);

    for (final key in [
      'history',
      'presets',
      'glossaries',
      'settings',
      'phrasebook',
      'practice',
      'future',
    ]) {
      await tester.ensureVisible(find.byKey(Key('backup_section_$key')));
      await tester.tap(find.byKey(Key('backup_section_$key')));
      await tester.pump();
    }
    await enterPassphrase(tester, 'correct horse battery staple');

    expect(createButton(tester).onPressed, isNull);
  });

  testWidgets('creates and saves the backup, then Done closes', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('backup_section_settings')));
    await enterPassphrase(tester, 'correct horse battery staple');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('backup_create_action')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('backup_create_saved')), findsOneWidget);
    expect(find.text('Backup saved'), findsOneWidget);
    final name = files.saved.keys.single;
    expect(name, startsWith('mozhi-'));
    expect(find.textContaining(name), findsOneWidget);
    expect(settings.exports, isEmpty);
    expect(await BackupStatusStore(prefs).lastBackupAt(), isNotNull);

    await tester.tap(find.byKey(const Key('backup_create_done')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('Done on the keyboard creates the backup', (tester) async {
    await open(tester);
    await enterPassphrase(tester, 'correct horse battery staple');

    await tester.runAsync(() async {
      await tester.showKeyboard(
        find.byKey(const Key('backup_passphrase_repeat')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('backup_create_saved')), findsOneWidget);
  });

  testWidgets('shows an hourglass instead of a spinner without '
      'animations', (tester) async {
    await open(tester);
    await enterPassphrase(tester, 'correct horse battery staple');
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.tap(find.byKey(const Key('backup_create_action')));
    await tester.pump();

    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('shows the progress while working', (tester) async {
    await open(tester);
    await enterPassphrase(tester, 'correct horse battery staple');

    await tester.tap(find.byKey(const Key('backup_create_action')));
    await tester.pump();

    expect(find.byKey(const Key('backup_create_working')), findsOneWidget);
    expect(find.text('Encrypting your backup…'), findsOneWidget);
    // Not closable now.
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.close),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('names a part it could not read', (tester) async {
    settings.failExport = true;
    await open(tester);
    await enterPassphrase(tester, 'correct horse battery staple');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('backup_create_action')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Couldn't read this part of your data: Settings. Leave it out or "
        'try again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('says when saving failed', (tester) async {
    files.saveError = StateError('disk full');
    await open(tester);
    await enterPassphrase(tester, 'correct horse battery staple');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('backup_create_action')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.text("Couldn't save the backup. Try again."), findsOneWidget);
  });

  testWidgets('Cancel closes without a backup', (tester) async {
    await open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(files.saved, isEmpty);
  });

  testWidgets('is a dialog on wide screens, closed with its button', (
    tester,
  ) async {
    await open(tester, size: const Size(1200, 900));

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(result, isFalse);
  });
}
