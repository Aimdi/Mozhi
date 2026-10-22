import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/settings_backup_section.dart';
import 'package:mozhi/backup/view/backup_restore_dialog.dart';
import 'package:mozhi/backup/view/backup_services.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../../helpers/helpers.dart';
import '../helpers/backup_fakes.dart';

void main() {
  final snapshot = BackupSnapshot(
    createdAt: DateTime.utc(2026, 10, 1, 8, 30),
    appVersion: '1.4.0+12',
    sections: {
      'history': const BackupSectionData(version: 1, data: [3, 4, 5]),
      'presets': const BackupSectionData(version: 1, data: 'no list'),
      'settings': BackupSectionData(
        version: 1,
        data: {
          'settings': const AppSettings(onboardingComplete: true).toJson(),
          'secrets': const {
            'apiKeys': {'p': 'k'},
          },
        },
      ),
      'flashcards': const BackupSectionData(version: 1, data: null),
    },
  );
  late Uint8List bytes;
  late BackupRegistry registry;
  late MemorySection history;
  late MemorySection presets;
  late FakeBackupFiles files;
  bool? result;

  setUpAll(() async {
    bytes = await testCodec.encrypt(snapshot, 'pass phrase words');
  });

  setUp(() {
    history = MemorySection('history', data: [1, 2]);
    presets = MemorySection('presets', data: const <Object?>[]);
    registry = BackupRegistry()
      ..register(history)
      ..register(presets)
      ..register(
        SettingsBackupSection(
          SettingsRepository(prefs: MemoryStore(), secrets: MemoryStore()),
        ),
      );
    files = FakeBackupFiles()
      ..picked = PickedBackupFile(
        name: 'mozhi-2026-10-01.mozhibackup',
        bytes: bytes,
      );
    BackupServices.files = files;
    BackupServices.codec = testCodec;
    result = null;
  });

  tearDown(() {
    BackupServices.files = const PlatformBackupFiles();
    BackupServices.codec = const BackupCodec();
  });

  Future<void> open(WidgetTester tester, {BackupSnapshot? from}) async {
    tester.view
      ..physicalSize = const Size(400, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      RepositoryProvider<BackupRegistry>.value(
        value: registry,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => result = await showBackupRestoreDialog(
                  context,
                  snapshot: from,
                ),
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

  Future<void> run(WidgetTester tester, Future<void> Function() action) async {
    await tester.runAsync(() async {
      await action();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  Future<void> unlock(WidgetTester tester, String passphrase) async {
    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_pick'))),
    );
    await tester.enterText(
      find.byKey(const Key('backup_restore_passphrase')),
      passphrase,
    );
    await tester.pump();
    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_unlock'))),
    );
  }

  testWidgets('asks for a file, then shows when it was made', (tester) async {
    await open(tester);
    expect(find.text('Restore from a backup'), findsOneWidget);
    expect(find.textContaining('Choose a .mozhibackup file'), findsOneWidget);

    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_pick'))),
    );

    expect(find.text('mozhi-2026-10-01.mozhibackup'), findsOneWidget);
    expect(find.textContaining('with Mozhi 1.4.0+12'), findsOneWidget);
    expect(find.textContaining('Oct 1, 2026'), findsOneWidget);
    final unlockButton = tester.widget<FilledButton>(
      find.byKey(const Key('backup_restore_unlock')),
    );
    expect(unlockButton.onPressed, isNull);
  });

  testWidgets('a wrong passphrase says so; the right one opens the '
      'backup', (tester) async {
    await open(tester);
    await unlock(tester, 'wrong words');

    expect(
      find.text('Wrong passphrase, or the file is damaged.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('backup_restore_passphrase')),
      'pass phrase words',
    );
    await tester.pump();
    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_unlock'))),
    );

    expect(find.text('Choose what to restore'), findsOneWidget);
  });

  testWidgets('shows what the backup holds', (tester) async {
    await open(tester);
    await unlock(tester, 'pass phrase words');

    expect(find.text('History and favorites'), findsOneWidget);
    expect(find.text('3 items'), findsOneWidget);
    expect(find.text('Presets'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('With API keys and passwords'), findsOneWidget);
    expect(
      find.text('Not supported by this version of Mozhi, left out: flashcards'),
      findsOneWidget,
    );
    expect(find.textContaining('Merge keeps what'), findsOneWidget);
    expect(
      tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .map((tile) => tile.value),
      [true, true, true],
    );
  });

  testWidgets('merges the chosen parts and says what changed', (tester) async {
    await open(tester);
    await unlock(tester, 'pass phrase words');
    await tester.tap(find.byKey(const Key('backup_restore_section_presets')));
    await tester.tap(find.byKey(const Key('backup_restore_section_settings')));
    await tester.pump();

    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_merge'))),
    );

    expect(find.text('Backup restored'), findsOneWidget);
    expect(find.text('5 now, 2 before'), findsOneWidget);
    expect(history.data, [1, 2, 3, 4, 5]);
    expect(presets.restores, isEmpty);

    await tester.tap(find.byKey(const Key('backup_restore_done')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('replace without counts says "Restored"', (tester) async {
    await open(tester);
    await unlock(tester, 'pass phrase words');
    await tester.tap(find.byKey(const Key('backup_restore_section_history')));
    await tester.tap(find.byKey(const Key('backup_restore_section_presets')));
    await tester.pump();

    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_replace'))),
    );

    expect(find.text('Restored'), findsOneWidget);
    expect(
      find.text('Not supported by this version of Mozhi, left out: flashcards'),
      findsNothing,
    );
  });

  testWidgets('nothing chosen: no restore', (tester) async {
    await open(tester);
    await unlock(tester, 'pass phrase words');
    for (final id in ['history', 'presets', 'settings']) {
      await tester.tap(find.byKey(Key('backup_restore_section_$id')));
    }
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('backup_restore_merge')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('backup_restore_replace')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('names a part that failed', (tester) async {
    history.failRestore = true;
    await open(tester);
    await unlock(tester, 'pass phrase words');

    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_merge'))),
    );

    expect(
      find.text(
        "Couldn't restore this part: History and favorites. The other parts "
        'were restored.',
      ),
      findsOneWidget,
    );
  });

  for (final (name, picked, error, message) in [
    (
      'not a backup',
      PickedBackupFile(name: 'a.txt', bytes: Uint8List.fromList([1])),
      null,
      "This isn't a Mozhi backup.",
    ),
    (
      'a newer one',
      PickedBackupFile(
        name: 'b.mozhibackup',
        bytes: Uint8List.fromList([...'MOZHIBAK'.codeUnits, 7, 0, 0]),
      ),
      null,
      'This backup was made by a newer version of Mozhi. Update the app to '
          'restore it.',
    ),
    (
      'too large',
      null,
      const BackupFileTooLargeException(),
      'This file is too large to be a Mozhi backup.',
    ),
    ('unreadable', null, StateError('io'), "Couldn't read the file."),
  ]) {
    testWidgets('says when the file is $name', (tester) async {
      files
        ..picked = picked
        ..pickError = error;
      await open(tester);

      await run(
        tester,
        () => tester.tap(find.byKey(const Key('backup_restore_pick'))),
      );

      expect(find.text(message), findsOneWidget);
    });
  }

  testWidgets('says when a file opens to a newer format', (tester) async {
    BackupServices.codec = _NewerCodec();
    await open(tester);

    await unlock(tester, 'pass phrase words');

    expect(
      find.text(
        'This backup was made by a newer version of Mozhi. Update the app to '
        'restore it.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('backup_restore_passphrase')), findsOneWidget);
  });

  testWidgets('Choose another file goes back', (tester) async {
    await open(tester);
    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_pick'))),
    );

    await tester.tap(find.text('Choose another file'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('backup_restore_pick')), findsOneWidget);
  });

  testWidgets('Cancel closes', (tester) async {
    await open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('starts at what a given backup holds', (tester) async {
    await open(tester, from: snapshot);

    expect(find.text('Choose what to restore'), findsOneWidget);
    expect(find.textContaining('with Mozhi 1.4.0+12'), findsOneWidget);
  });

  testWidgets('shows the progress while unlocking and restoring', (
    tester,
  ) async {
    final unlocking = Completer<void>();
    final restoring = Completer<void>();
    BackupServices.codec = _WaitingCodec(unlocking.future);
    history.waitFor = restoring.future;
    await open(tester);
    await run(
      tester,
      () => tester.tap(find.byKey(const Key('backup_restore_pick'))),
    );
    await tester.enterText(
      find.byKey(const Key('backup_restore_passphrase')),
      'pass phrase words',
    );
    await tester.runAsync(
      () => tester.testTextInput.receiveAction(TextInputAction.done),
    );
    await tester.pump();

    expect(find.byKey(const Key('backup_restore_unlocking')), findsOneWidget);
    expect(find.text('Unlocking the backup…'), findsOneWidget);
    await tester.runAsync(() async {
      unlocking.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump();

    await tester.runAsync(
      () => tester.tap(find.byKey(const Key('backup_restore_merge'))),
    );
    await tester.pump();
    expect(find.byKey(const Key('backup_restore_restoring')), findsOneWidget);
    await tester.runAsync(() async {
      restoring.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Backup restored'), findsOneWidget);
  });
}

/// [testCodec] whose decrypt waits for [gate].
class _WaitingCodec extends BackupCodec {
  new(this.gate)
    : super(
        kdf: const BackupKdf(memory: 64, iterations: 1, parallelism: 1),
        useIsolate: false,
      );

  final Future<void> gate;

  @override
  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) async {
    await gate;
    return await super.decrypt(bytes, passphrase);
  }
}

/// A codec whose backups all open to a newer format.
class _NewerCodec extends BackupCodec {
  new()
    : super(
        kdf: const BackupKdf(memory: 64, iterations: 1, parallelism: 1),
        useIsolate: false,
      );

  @override
  Future<BackupSnapshot> decrypt(Uint8List bytes, String passphrase) =>
      Future.error(
        const BackupFormatException(
          message: 'Newer backup format',
          newerVersion: true,
        ),
      );
}
