import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/data/backup_status_store.dart';
import 'package:mozhi/backup/view/backup_services.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/view/categories/backup_settings.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';

import '../../../backup/helpers/backup_fakes.dart';
import '../../../helpers/helpers.dart';

/// A store whose reads fail.
class _BrokenStore extends MemoryStore {
  @override
  Future<String?> read(String key) => Future.error(StateError('broken'));
}

void main() {
  late MemoryStore prefs;
  late BackupRegistry registry;
  late FakeBackupFiles files;

  setUp(() {
    prefs = MemoryStore();
    registry = BackupRegistry(appVersion: () async => '1')
      ..register(MemorySection('history', data: [1]));
    files = FakeBackupFiles();
    BackupServices.files = files;
    BackupServices.codec = testCodec;
  });

  tearDown(() {
    BackupServices.files = const PlatformBackupFiles();
    BackupServices.codec = const BackupCodec();
  });

  Future<void> pump(WidgetTester tester, {KeyValueStore? store}) async {
    tester.view
      ..physicalSize = const Size(400, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BackupRegistry>.value(value: registry),
          RepositoryProvider<KeyValueStore>.value(value: store ?? prefs),
        ],
        child: const Scaffold(
          body: SingleChildScrollView(child: EncryptedBackupSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the backup rows with their anchors', (tester) async {
    await pump(tester);

    expect(find.text('Encrypted backup'), findsOneWidget);
    expect(find.textContaining('only your passphrase opens'), findsOneWidget);
    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('No backup yet'), findsOneWidget);
    expect(find.text('Restore from a backup'), findsOneWidget);
    for (final anchor in [BackupAnchors.backUp, BackupAnchors.restore]) {
      expect(find.byKey(SettingsAnchor.highlightKey(anchor)), findsOneWidget);
    }
  });

  testWidgets('shows the date of the last backup', (tester) async {
    await BackupStatusStore(prefs).recordBackup(DateTime(2026, 10, 1, 9, 5));

    await pump(tester);

    expect(
      find.textContaining(RegExp(r'^Last backup: Oct 1, 2026,? 9:05\sAM$')),
      findsOneWidget,
    );
  });

  testWidgets('a failing store reads as no backup', (tester) async {
    await pump(tester, store: _BrokenStore());

    expect(find.text('No backup yet'), findsOneWidget);
  });

  testWidgets('works without the preferences', (tester) async {
    await tester.pumpApp(
      const Scaffold(
        body: SingleChildScrollView(child: EncryptedBackupSettings()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No backup yet'), findsOneWidget);
  });

  testWidgets('Back up now opens the backup and shows its date '
      'afterwards', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('settings_backup_create')));
    await tester.pumpAndSettle();
    expect(find.text('Back up your data'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('backup_passphrase')),
      'correct horse battery staple',
    );
    await tester.enterText(
      find.byKey(const Key('backup_passphrase_repeat')),
      'correct horse battery staple',
    );
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('backup_create_action')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup_create_done')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(files.saved, hasLength(1));
    expect(find.textContaining('Last backup: '), findsOneWidget);
  });

  testWidgets('Restore opens the restore', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('settings_backup_restore')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('backup_restore_pick')), findsOneWidget);
  });
}
