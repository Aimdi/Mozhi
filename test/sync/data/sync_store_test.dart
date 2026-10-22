import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/sync/data/sync_store.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';

/// A store whose every operation fails.
class _BrokenStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw Exception('broken');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('broken');

  @override
  Future<void> delete(String key) async => throw Exception('broken');
}

void main() {
  late MemoryStore prefs;
  late MemoryStore secrets;
  late SyncStore store;

  setUp(() {
    prefs = MemoryStore();
    secrets = MemoryStore();
    store = SyncStore(prefs: prefs, secrets: secrets);
  });

  final key = BackupKey(
    key: Uint8List(32),
    salt: Uint8List(16),
    kdf: BackupKdf.browser,
  );

  test('keeps the config and state in the preferences', () async {
    final config = SyncConfig(
      server: Uri.parse('https://a.example/dav/'),
      username: 'u',
    );
    await store.writeConfig(config);
    final status = const SyncStatus().succeeded(
      DateTime.utc(2026),
      SyncResult.sent,
    );
    await store.writeState(status, const SyncCursor(fingerprint: 'f'));
    expect(prefs.values.keys, {SyncStore.configKey, SyncStore.stateKey});
    expect(await store.readConfig(), config);
    final (readStatus, cursor) = await store.readState();
    expect(readStatus.lastResult, SyncResult.sent);
    expect(cursor, const SyncCursor(fingerprint: 'f'));
    expect(secrets.values, isEmpty);
  });

  test('keeps the password and key in secure storage', () async {
    await store.writePassword('pw');
    await store.writeKey(key);
    expect(secrets.values.keys, {SyncStore.passwordKey, SyncStore.keyKey});
    expect(await store.readPassword(), 'pw');
    expect(await store.readKey(), key);
    expect(prefs.values, isEmpty);
  });

  test('reads nothing from empty, broken or invalid stores', () async {
    expect(await store.readConfig(), isNull);
    expect(await store.readState(), (const SyncStatus(), null));
    expect(await store.readPassword(), isNull);
    expect(await store.readKey(), isNull);
    secrets.values[SyncStore.passwordKey] = '';
    secrets.values[SyncStore.keyKey] = jsonEncode({'key': 'x'});
    prefs.values[SyncStore.stateKey] = '[1]';
    prefs.values[SyncStore.configKey] = 'not json';
    expect(await store.readPassword(), isNull);
    expect(await store.readKey(), isNull);
    expect(await store.readConfig(), isNull);
    expect((await store.readState()).$1, const SyncStatus());
    secrets.values[SyncStore.keyKey] = '"text"';
    expect(await store.readKey(), isNull);
    final broken = SyncStore(prefs: _BrokenStore(), secrets: _BrokenStore());
    expect(await broken.readConfig(), isNull);
    expect(await broken.readPassword(), isNull);
    expect(await broken.readKey(), isNull);
  });

  test('clear deletes everything, and tries every key', () async {
    await store.writePassword('pw');
    await store.writeKey(key);
    await store.writeConfig(
      SyncConfig(server: Uri.parse('https://a.example'), username: 'u'),
    );
    await store.writeState(const SyncStatus(), null);
    prefs.values['other'] = 'kept';
    await store.clear();
    expect(secrets.values, isEmpty);
    expect(prefs.values, {'other': 'kept'});
    await expectLater(
      SyncStore(prefs: prefs, secrets: _BrokenStore()).clear(),
      throwsException,
    );
  });
}
