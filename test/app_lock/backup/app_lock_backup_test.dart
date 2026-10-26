import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/sections/settings_backup_section.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

/// The app lock is a setting of one device: backups, sync and phone to
/// phone (all made of `SettingsBackupSection` data) never carry it, and a
/// restore never changes it.
void main() {
  late SettingsRepository repository;
  late SettingsBackupSection section;

  setUp(() async {
    repository = SettingsRepository(
      prefs: MemoryStore(),
      secrets: MemoryStore(),
    );
    section = SettingsBackupSection(repository);
  });

  Future<void> store(AppSettings settings) => repository.save(settings);

  /// [data] through JSON, as a backup file carries it.
  Object? throughJson(Object? data) => jsonDecode(jsonEncode(data));

  test('is a device-only field', () {
    expect(SettingsBackupSection.deviceOnlyFields, contains('appLock'));
  });

  group('export', () {
    for (final includeSecrets in [false, true]) {
      test('leaves the app lock out (secrets: $includeSecrets)', () async {
        await store(
          const AppSettings(
            onboardingComplete: true,
            appLock: AppLockTimeout.immediately,
          ),
        );

        final data =
            (await section.export(includeSecrets: includeSecrets))! as Map;
        final settings = data['settings'] as Map;

        expect(settings, isNot(contains('appLock')));
        expect(settings['onboardingComplete'], isTrue);
        expect(jsonEncode(data), isNot(contains('immediately')));
      });
    }
  });

  group('restore', () {
    Map<String, Object?> backup(AppSettings settings) => {
      'settings': settings.toJson(),
    };

    for (final mode in BackupRestoreMode.values) {
      test("${mode.name} keeps this device's app lock on", () async {
        await store(
          const AppSettings(
            onboardingComplete: true,
            appLock: AppLockTimeout.after5Minutes,
          ),
        );

        await section.restore(
          throughJson(
            backup(const AppSettings(privacyMode: PrivacyMode.online)),
          ),
          version: 1,
          mode: mode,
        );

        expect((await repository.load()).appLock, AppLockTimeout.after5Minutes);
      });

      test('${mode.name} never turns the lock on from a file', () async {
        await store(const AppSettings(onboardingComplete: true));

        // A file from an older version, or a crafted one, that has it.
        await section.restore(
          throughJson(
            backup(const AppSettings(appLock: AppLockTimeout.immediately)),
          ),
          version: 1,
          mode: mode,
        );

        expect((await repository.load()).appLock, AppLockTimeout.off);
      });
    }

    test('replace still takes the rest of the backup', () async {
      await store(
        const AppSettings(
          onboardingComplete: true,
          appLock: AppLockTimeout.immediately,
        ),
      );

      await section.restore(
        throughJson(backup(const AppSettings(privacyMode: PrivacyMode.online))),
        version: 1,
        mode: BackupRestoreMode.replace,
      );

      final restored = await repository.load();
      expect(restored.privacyMode, PrivacyMode.online);
      expect(restored.appLock, AppLockTimeout.immediately);
    });
  });

  test('a snapshot from another device (as sync and phone to phone '
      'merge it) leaves both locks as they were', () async {
    final other = SettingsRepository(
      prefs: MemoryStore(),
      secrets: MemoryStore(),
    );
    await other.save(
      const AppSettings(
        onboardingComplete: true,
        appLock: AppLockTimeout.after15Minutes,
      ),
    );
    final theirs = BackupRegistry(appVersion: () async => '1.0.0')
      ..register(SettingsBackupSection(other));
    final mine = BackupRegistry(appVersion: () async => '1.0.0')
      ..register(section);
    await store(const AppSettings(onboardingComplete: true));
    addTearDown(theirs.dispose);
    addTearDown(mine.dispose);

    final snapshot = BackupSnapshot.fromJson(
      throughJson((await theirs.snapshot(includeSecrets: true)).toJson())!
          as Map<String, Object?>,
    );
    for (final mode in BackupRestoreMode.values) {
      await mine.restore(snapshot, mode: mode);
      expect((await repository.load()).appLock, AppLockTimeout.off);
    }

    await theirs.restore(
      await mine.snapshot(includeSecrets: false),
      mode: BackupRestoreMode.replace,
    );
    expect((await other.load()).appLock, AppLockTimeout.after15Minutes);
  });
}
