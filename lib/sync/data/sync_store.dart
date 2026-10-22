import 'dart:convert';

import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';

/// Where sync keeps what it needs between starts: the [SyncConfig] and the
/// last [SyncStatus] and [SyncCursor] as JSON in the plain [prefs], the app
/// password and the derived key ([BackupKey], never the passphrase) in
/// [secrets] (secure storage).
///
/// Reads never throw: what can't be read (or parsed) is null.
class SyncStore {
  new({required this.prefs, required this.secrets});

  /// Key of the [SyncConfig] in [prefs].
  static const configKey = 'sync.v1';

  /// Key of the [SyncStatus] and [SyncCursor] in [prefs].
  static const stateKey = 'sync.state.v1';

  /// Key of the app password in [secrets].
  static const passwordKey = 'sync.password';

  /// Key of the derived key in [secrets].
  static const keyKey = 'sync.key';

  final KeyValueStore prefs;
  final KeyValueStore secrets;

  Future<SyncConfig?> readConfig() async =>
      SyncConfig.tryParse(await _readJson(prefs, configKey));

  Future<void> writeConfig(SyncConfig config) =>
      prefs.write(configKey, jsonEncode(config.toJson()));

  /// The last status (empty when none) and cursor.
  Future<(SyncStatus, SyncCursor?)> readState() async {
    final json = await _readJson(prefs, stateKey);
    final map = json is Map ? json : const <String, Object?>{};
    return (
      SyncStatus.fromJson(map['status']),
      SyncCursor.tryParse(map['cursor']),
    );
  }

  Future<void> writeState(SyncStatus status, SyncCursor? cursor) => prefs.write(
    stateKey,
    jsonEncode({'status': status.toJson(), 'cursor': cursor?.toJson()}),
  );

  Future<String?> readPassword() async {
    try {
      final password = await secrets.read(passwordKey);
      return (password?.isEmpty ?? true) ? null : password;
    } on Object {
      return null;
    }
  }

  Future<void> writePassword(String password) =>
      secrets.write(passwordKey, password);

  Future<BackupKey?> readKey() async {
    final json = await _readJson(secrets, keyKey);
    if (json is! Map<String, Object?>) return null;
    try {
      return BackupKey.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeKey(BackupKey key) =>
      secrets.write(keyKey, jsonEncode(key.toJson()));

  /// Deletes everything sync stored on this device (the server is not
  /// touched). Every key is attempted; the first error is rethrown.
  Future<void> clear() async {
    Object? failure;
    StackTrace? failureTrace;
    for (final (store, key) in [
      (secrets, keyKey),
      (secrets, passwordKey),
      (prefs, stateKey),
      (prefs, configKey),
    ]) {
      try {
        await store.delete(key);
      } on Object catch (error, stackTrace) {
        failure ??= error;
        failureTrace ??= stackTrace;
      }
    }
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureTrace ?? StackTrace.current);
    }
  }

  static Future<Object?> _readJson(KeyValueStore store, String key) async {
    try {
      final raw = await store.read(key);
      return raw == null ? null : jsonDecode(raw);
    } on Object {
      return null;
    }
  }
}
