import 'dart:typed_data';

import 'package:mozhi/backup/data/backup_codec.dart';
import 'package:mozhi/backup/data/backup_files.dart';
import 'package:mozhi/backup/data/backup_registry.dart';

/// A fast codec for tests: tiny Argon2id parameters, no isolate.
const testCodec = BackupCodec(
  kdf: BackupKdf(memory: 64, iterations: 1, parallelism: 1),
  useIsolate: false,
);

/// A section holding [data] in memory, counting the items of a list.
class MemorySection implements BackupSection, BackupItemCounter {
  new(this.id, {this.data, this.failExport = false});

  @override
  final String id;

  @override
  int get version => 1;

  Object? data;
  bool failExport;
  bool failRestore = false;

  /// When set, [restore] waits for it first.
  Future<void>? waitFor;
  final restores = <BackupRestoreMode>[];
  final exports = <bool>[];

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    exports.add(includeSecrets);
    if (failExport) throw StateError('export failed');
    return data;
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    if (waitFor case final wait?) await wait;
    if (failRestore) throw StateError('restore failed');
    restores.add(mode);
    this.data = switch ((mode, this.data, data)) {
      (
        BackupRestoreMode.merge,
        final List<Object?> mine,
        final List<Object?> theirs,
      ) =>
        [
          ...mine,
          for (final item in theirs)
            if (!mine.contains(item)) item,
        ],
      _ => data,
    };
  }

  @override
  int? countItems(Object? data, {required int version}) =>
      data is List ? data.length : null;

  @override
  Future<int> countLocalItems() async => (data as List?)?.length ?? 0;
}

/// [BackupFiles] that saves into [saved] and picks [picked].
class FakeBackupFiles implements BackupFiles {
  final saved = <String, Uint8List>{};

  /// What [save] returns (false: the user cancelled).
  bool accept = true;

  /// Thrown by [save] when set.
  Object? saveError;

  /// What [pick] returns (null: cancelled).
  PickedBackupFile? picked;

  /// Thrown by [pick] when set.
  Object? pickError;

  @override
  Future<PickedBackupFile?> pick() async {
    if (pickError case final error?) {
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    return picked;
  }

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (saveError case final error?) {
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    if (!accept) return false;
    saved[fileName] = bytes;
    return true;
  }
}
