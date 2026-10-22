import 'package:mozhi/core/key_value_store.dart';

/// When the last backup was saved on this device (the only thing backups
/// store; never the passphrase or the key). Kept in the app's preferences
/// under [lastBackupKey].
class BackupStatusStore {
  const new(this._store);

  /// Key of the last backup's time (UTC ISO 8601) in the preferences.
  static const lastBackupKey = 'backup.lastBackupAt';

  final KeyValueStore _store;

  /// When the last backup was saved; null when none was (or the value is
  /// unreadable).
  Future<DateTime?> lastBackupAt() async {
    final value = await _store.read(lastBackupKey);
    return value == null ? null : DateTime.tryParse(value)?.toLocal();
  }

  /// Records that a backup was saved [at].
  Future<void> recordBackup(DateTime at) =>
      _store.write(lastBackupKey, at.toUtc().toIso8601String());

  /// Forgets the last backup (Delete all local data).
  Future<void> delete() => _store.delete(lastBackupKey);
}
