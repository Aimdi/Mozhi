import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_registry.dart';

/// A cheap key derivation for tests (Argon2id with 8 KiB, one pass).
const testKdf = BackupKdf(memory: 8, iterations: 1, parallelism: 1);

/// A codec with [testKdf] that runs in the test's isolate.
const testCodec = BackupCodec(kdf: testKdf, useIsolate: false);

/// One entry of a [MemorySection]: a value and when it last changed, or a
/// tombstone (`deleted`).
typedef MemoryEntry = ({String value, int updatedAt, bool deleted});

/// A `BackupSection` over a map of entries, merged like the app's
/// sections: per entry the newer copy wins, tombstones included.
class MemorySection implements BackupSection {
  new(this.id, {this.version = 1, Map<String, MemoryEntry>? entries})
    : entries = {...?entries};

  @override
  final String id;

  @override
  final int version;

  final Map<String, MemoryEntry> entries;

  /// Restores applied, in order.
  final restores = <BackupRestoreMode>[];

  /// The secrets flag of each export.
  final exports = <bool>[];

  /// Thrown by [export] / [restore] when set.
  Exception? exportError;
  Exception? restoreError;

  /// The values that are not deleted.
  Map<String, String> get values => {
    for (final MapEntry(:key, :value) in entries.entries)
      if (!value.deleted) key: value.value,
  };

  void set(String key, String value, int at) =>
      entries[key] = (value: value, updatedAt: at, deleted: false);

  void delete(String key, int at) =>
      entries[key] = (value: '', updatedAt: at, deleted: true);

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    exports.add(includeSecrets);
    if (exportError case final error?) throw error;
    final keys = entries.keys.toList()..sort();
    return {
      'entries': [
        for (final key in keys)
          {
            'key': key,
            'value': entries[key]!.value,
            'updatedAt': entries[key]!.updatedAt,
            if (entries[key]!.deleted) 'deleted': true,
          },
      ],
      if (includeSecrets) 'secret': 'sk-test',
    };
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    restores.add(mode);
    if (restoreError case final error?) throw error;
    if (version > this.version) throw const FormatException('newer');
    final incoming = {
      for (final item
          in ((data! as Map<String, Object?>)['entries']! as List)
              .cast<Map<String, Object?>>())
        item['key']! as String: (
          value: item['value']! as String,
          updatedAt: item['updatedAt']! as int,
          deleted: item['deleted'] == true,
        ),
    };
    if (mode == BackupRestoreMode.replace) {
      entries
        ..clear()
        ..addAll(incoming);
      return;
    }
    for (final MapEntry(:key, :value) in incoming.entries) {
      final mine = entries[key];
      if (mine == null || value.updatedAt > mine.updatedAt) {
        entries[key] = value;
      }
    }
  }
}

/// A registry of [sections] with a fixed clock and app version.
BackupRegistry registryOf(List<BackupSection> sections) {
  final registry = BackupRegistry(
    appVersion: () async => '1.0.0+1',
    clock: () => DateTime.utc(2026, 10, 22, 12),
  );
  sections.forEach(registry.register);
  return registry;
}
