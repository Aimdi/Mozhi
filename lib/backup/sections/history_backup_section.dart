import 'dart:math';

import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';

/// The history and favorites ([HistoryEntry]) with their deletion
/// tombstones ([HistoryTombstone]), section `history`.
///
/// Data (version 1): `{"entries": [HistoryEntry.toJson()...],
/// "tombstones": [HistoryTombstone.toJson()...]}`. Restoring skips invalid
/// entries and tombstones; [BackupRestoreMode.replace] uses
/// [HistoryRepository.replaceAll], [BackupRestoreMode.merge]
/// [HistoryRepository.mergeBackup] (the newer copy of an entry wins,
/// tombstones keep deleted entries deleted).
///
/// A merge applies this device's "Delete history automatically": `maxAge`
/// tells how long it keeps non-favorites (null, or a null result: for
/// ever; it is asked at every merge, and a failure counts as for ever), so
/// that a merge never brings back entries the retention deleted here.
///
/// In the sync file ([syncData]) the retention deletes nothing on other
/// devices: what it removed here leaves no tombstone, and the file keeps
/// it for the devices that keep history longer. Each device records how
/// long it keeps history (`"retention": [{"maxAgeSeconds": 604800 | null,
/// "seenAt": "…Z"}]`, one record per retention, renewed by a device that
/// syncs at most every [retentionRenewal] and dropped when not renewed
/// for [retentionLifetime]). A device writes back the file's entries it
/// dropped by its own retention as long as some record keeps them, so
/// that devices with different settings write the same file instead of
/// taking turns adding and removing them; entries older than every
/// record's retention leave the file. A file without records (earlier
/// versions write none) keeps nothing for others: such a device writes
/// back its own history, as before. `clock` (the current time) defaults
/// to [DateTime.now].
class HistoryBackupSection
    implements BackupSection, BackupItemCounter, BackupSyncSection {
  new(this._repository, {this._maxAge, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The section's [id].
  static const sectionId = 'history';

  final HistoryRepository _repository;
  final Future<Duration?> Function()? _maxAge;
  final DateTime Function() _clock;

  /// How long a retention record of the sync file counts without being
  /// renewed (by a device with that retention that synced).
  static const retentionLifetime = Duration(days: 30);

  /// How old a device's own retention record gets before a sync renews it
  /// (each renewal writes the file once more).
  static const retentionRenewal = Duration(days: 7);

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
        await _repository.mergeBackup(
          entries,
          tombstones: tombstones,
          maxAge: await _retention(),
        );
    }
  }

  /// This device's retention; null (for ever) when it can't be read: the
  /// history then applies it at its next load.
  Future<Duration?> _retention() async {
    try {
      return await _maxAge?.call();
    } on Object {
      return null;
    }
  }

  @override
  Future<Object?> syncData(
    Object? local, {
    required Object? remote,
    required int? remoteVersion,
  }) async {
    if (local is! Map) return local;
    final now = _clock().toUtc();
    final maxAge = await _retention();
    final records = remote is Map && (remoteVersion ?? 0) <= version
        ? _records(remote['retention'], now)
        : <int?, DateTime>{};
    final own = maxAge?.inSeconds;
    final seen = records[own];
    if (seen == null || now.difference(seen) >= retentionRenewal) {
      records[own] = DateTime.utc(now.year, now.month, now.day);
    }
    final entries = [...?(local['entries'] as List?)];
    final carried = maxAge == null || remote is! Map
        ? const <({DateTime createdAt, Object json})>[]
        : _carried(
            remote['entries'],
            local: local,
            before: now.subtract(maxAge),
            notBefore: records.containsKey(null)
                ? null
                : now.subtract(
                    Duration(
                      seconds: records.keys.whereType<int>().fold(0, max),
                    ),
                  ),
          );
    // Shortest first, for ever last.
    final keys = records.keys.toList()
      ..sort(
        (a, b) => a == null || b == null
            ? (a == null ? 1 : 0) - (b == null ? 1 : 0)
            : a.compareTo(b),
      );
    return {
      ...local,
      'entries': carried.isEmpty ? entries : _interleaved(entries, carried),
      'retention': [
        for (final key in keys)
          {
            'maxAgeSeconds': key,
            'seenAt': records[key]!.toUtc().toIso8601String(),
          },
      ],
    };
  }

  /// The retention records of a sync file (`retention`) that still count
  /// at [now]: seconds history is kept (null: for ever) → last renewed.
  static Map<int?, DateTime> _records(Object? json, DateTime now) {
    final cutoff = now.subtract(retentionLifetime);
    final records = <int?, DateTime>{};
    if (json is! List) return records;
    for (final record in json) {
      if (record is! Map || !record.containsKey('maxAgeSeconds')) continue;
      final seconds = record['maxAgeSeconds'];
      final seenAt = switch (record['seenAt']) {
        final String iso => DateTime.tryParse(iso)?.toUtc(),
        _ => null,
      };
      if ((seconds != null && (seconds is! int || seconds < 0)) ||
          seenAt == null ||
          seenAt.isBefore(cutoff)) {
        continue;
      }
      final key = seconds as int?;
      final known = records[key];
      if (known == null || seenAt.isAfter(known)) records[key] = seenAt;
    }
    return records;
  }

  /// The file's [entries] this device doesn't hold because its retention
  /// dropped them (created [before] its cutoff, not favorites, without a
  /// tombstone here) and that another device still keeps (created no
  /// earlier than [notBefore]; null: one keeps them for ever), newest
  /// first, as the file has them.
  static List<({DateTime createdAt, Object json})> _carried(
    Object? entries, {
    required Map<dynamic, dynamic> local,
    required DateTime before,
    required DateTime? notBefore,
  }) {
    if (entries is! List) return const [];
    final ids = <String>{
      for (final json in [...?(local['entries'] as List?)])
        if (json is Map && json['id'] is String) json['id'] as String,
    };
    final deleted = <String, DateTime>{
      for (final json in [...?(local['tombstones'] as List?)])
        if (json is Map)
          if (_parsed(() => HistoryTombstone.fromJson(Map.from(json)))
              case final tombstone?)
            tombstone.id: tombstone.deletedAt,
    };
    final carried = <({DateTime createdAt, Object json})>[];
    for (final json in entries) {
      if (json is! Map) continue;
      final entry = _parsed(() => HistoryEntry.fromJson(Map.from(json)));
      if (entry == null || entry.isFavorite || !ids.add(entry.id)) continue;
      if (deleted[entry.id] case final at? when !entry.modifiedAt.isAfter(at)) {
        continue;
      }
      if (!entry.createdAt.isBefore(before)) continue;
      if (notBefore != null && entry.createdAt.isBefore(notBefore)) continue;
      carried.add((createdAt: entry.createdAt, json: json));
    }
    return carried..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// [entries] (this device's, newest first) with [carried] (newest
  /// first) put in by creation time, after entries created at the same
  /// time.
  static List<Object?> _interleaved(
    List<Object?> entries,
    List<({DateTime createdAt, Object json})> carried,
  ) {
    final result = <Object?>[];
    var next = 0;
    for (final json in entries) {
      final createdAt = json is Map
          ? _parsed(() => HistoryEntry.fromJson(Map.from(json)))?.createdAt
          : null;
      while (createdAt != null &&
          next < carried.length &&
          carried[next].createdAt.isAfter(createdAt)) {
        result.add(carried[next++].json);
      }
      result.add(json);
    }
    for (; next < carried.length; next++) {
      result.add(carried[next].json);
    }
    return result;
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

  /// What [parse] returns, or null when it throws anything (data of the
  /// sync file that this device only passes on).
  static T? _parsed<T>(T Function() parse) {
    try {
      return parse();
    } on Object {
      return null;
    }
  }
}
