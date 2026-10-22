import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';

/// The history and favourites ([HistoryEntry]) with their deletion
/// tombstones ([HistoryTombstone]), section `history`.
///
/// Data (version 1): `{"entries": [HistoryEntry.toJson()...],
/// "tombstones": [HistoryTombstone.toJson()...]}`. Restoring skips invalid
/// entries and tombstones; [BackupRestoreMode.replace] uses
/// [HistoryRepository.replaceAll], [BackupRestoreMode.merge]
/// [HistoryRepository.mergeBackup] (the newer copy of an entry wins,
/// tombstones keep deleted entries deleted).
class HistoryBackupSection implements BackupSection, BackupItemCounter {
  const new(this._repository);

  /// The section's [id].
  static const sectionId = 'history';

  final HistoryRepository _repository;

  @override
  String get id => sectionId;

  @override
  int get version => 1;

  @override
  Future<Object?> export({required bool includeSecrets}) async {
    final data = await _repository.backupData();
    return {
      'entries': [for (final entry in data.entries) entry.toJson()],
      'tombstones': [
        for (final tombstone in data.tombstones) tombstone.toJson(),
      ],
    };
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    final (:entries, :tombstones) = _parse(data, version);
    switch (mode) {
      case BackupRestoreMode.replace:
        await _repository.replaceAll(entries, tombstones: tombstones);
      case BackupRestoreMode.merge:
        await _repository.mergeBackup(entries, tombstones: tombstones);
    }
  }

  @override
  int? countItems(Object? data, {required int version}) {
    try {
      return _parse(data, version).entries.length;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<int> countLocalItems() async =>
      (await _repository.backupData()).entries.length;

  ({List<HistoryEntry> entries, List<HistoryTombstone> tombstones}) _parse(
    Object? data,
    int version,
  ) {
    if (version > this.version) {
      throw FormatException('History data version $version is newer');
    }
    if (data case {'entries': final List<dynamic> entries}) {
      final tombstones = data['tombstones'];
      return (
        entries: [
          for (final json in entries)
            if (json is Map)
              ?_tryParse(() => HistoryEntry.fromJson(Map.from(json))),
        ],
        tombstones: [
          if (tombstones is List)
            for (final json in tombstones)
              if (json is Map)
                ?_tryParse(() => HistoryTombstone.fromJson(Map.from(json))),
        ],
      );
    }
    throw const FormatException('Invalid history data');
  }

  static T? _tryParse<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException {
      return null;
    }
  }
}
