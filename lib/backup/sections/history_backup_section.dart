import 'dart:math';

import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/sync/data/sync_merge.dart';

/// The history and favorites ([HistoryEntry]) with their deletion
/// tombstones ([HistoryTombstone]), section `history`.
///
/// Data (version 1): `{"entries": [HistoryEntry.toJson()...],
/// "tombstones": [HistoryTombstone.toJson()...], "cleared":
/// HistoryCleared.toJson()}` (`cleared` only once Clear history ran;
/// versions before it ignore it). Restoring skips invalid entries and
/// tombstones; [BackupRestoreMode.replace] uses
/// [HistoryRepository.replaceAll], [BackupRestoreMode.merge]
/// [HistoryRepository.mergeBackup] (the newer copy of an entry wins,
/// tombstones keep deleted entries deleted).
///
/// The record of clears (`cleared`) counts only in a sync merge
/// ([forSyncMerge], with when this device joined the folder,
/// [HistorySyncMerge]; see [HistoryRepository.mergeBackup]): the folder's
/// clears take what they cover, but never this device's history from
/// before it joined. A backup's or another phone's record is ignored:
/// restoring never deletes this device's entries by a clear.
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
/// back its own history, as before. A record more than
/// [HistoryCleared.maxClockSkew] ahead of the clock (a device whose clock
/// is wrong) is dropped, and one ahead by less counts as renewed today,
/// so that no record keeps history in the file for ever.
///
/// The file's record of clears is this device's clears from since it
/// joined ([SyncMergeContext.joinedAt]) with the file's own (a clear this
/// device made before it joined never reaches the folder). The file's
/// entries that record covers are never written back, and get a
/// tombstone (here too) when this device has none for them.
/// `clock` (the current time) defaults to [DateTime.now].
class HistoryBackupSection
    implements
        BackupSection,
        BackupItemCounter,
        BackupSyncSection,
        SyncMergeSection {
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
      if (!data.cleared.isEmpty) 'cleared': data.cleared.toJson(),
    };
  }

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) async {
    final context = data is _SyncMerge ? data.context : null;
    final (:entries, :tombstones, :cleared) = _parse(
      data is _SyncMerge ? data.data : data,
      version,
    );
    switch (mode) {
      case BackupRestoreMode.replace:
        await _repository.replaceAll(entries, tombstones: tombstones);
      case BackupRestoreMode.merge:
        await _repository.mergeBackup(
          entries,
          tombstones: tombstones,
          maxAge: await _retention(),
          sync: context == null
              ? null
              : HistorySyncMerge(cleared: cleared, joinedAt: context.joinedAt),
        );
    }
  }

  @override
  Object? forSyncMerge(Object? data, SyncMergeContext context) =>
      _SyncMerge(data, context);

  /// This device's retention; null (for ever) when it can't be read: the
  /// history then applies it at its next load.
  Future<Duration?> _retention() async {
    try {
      return await _maxAge?.call();
    } on Object {
      return null;
    }
  }

  /// [syncDataIn] for a device that has synced with the folder all along.
  @override
  Future<Object?> syncData(
    Object? local, {
    required Object? remote,
    required int? remoteVersion,
  }) => syncDataIn(
    const SyncMergeContext(),
    local,
    remote: remote,
    remoteVersion: remoteVersion,
  );

  @override
  Future<Object?> syncDataIn(
    SyncMergeContext context,
    Object? local, {
    required Object? remote,
    required int? remoteVersion,
  }) async {
    if (local is! Map) return local;
    var data = local;
    final now = _clock().toUtc();
    final maxAge = await _retention();
    final readable = remote is Map && (remoteVersion ?? 0) <= version;
    final records = readable
        ? _records(remote['retention'], now)
        : <int?, DateTime>{};
    // The folder's clears: this device's since it joined, and the file's.
    final cleared = HistoryCleared.fromJson(data['cleared'])
        .since(context.joinedAt)
        .union(
          readable
              ? HistoryCleared.fromJson(remote['cleared']).validAt(now)
              : HistoryCleared.none,
        );
    data = {...data}..remove('cleared');
    if (!cleared.isEmpty) data['cleared'] = cleared.toJson();
    if (readable && !cleared.isEmpty) {
      data = await _withClearedTombstones(data, remote['entries'], cleared);
    }
    final own = maxAge?.inSeconds;
    final seen = records[own];
    if (seen == null || now.difference(seen) >= retentionRenewal) {
      records[own] = DateTime.utc(now.year, now.month, now.day);
    }
    final entries = [...?(data['entries'] as List?)];
    final carried = maxAge == null || remote is! Map
        ? const <({DateTime createdAt, Object json})>[]
        : _carried(
            remote['entries'],
            local: data,
            cleared: cleared,
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
      ...data,
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

  /// [local] with tombstones for the file's [entries] that [cleared]
  /// covers and that this device neither holds nor has a tombstone for
  /// (it didn't merge the file since, e.g. the file holds what it wrote
  /// last): they are recorded here too (so the next export holds them),
  /// and reach the devices that hold the entries, also those that don't
  /// know the record. [local] as it is when there are none, or they can't
  /// be recorded.
  Future<Map<dynamic, dynamic>> _withClearedTombstones(
    Map<dynamic, dynamic> local,
    Object? entries,
    HistoryCleared cleared,
  ) async {
    if (entries is! List) return local;
    final ids = _ids(local);
    final deleted = _deleted(local);
    final covered = <HistoryTombstone>[];
    for (final json in entries) {
      if (json is! Map) continue;
      final entry = _parsed(() => HistoryEntry.fromJson(Map.from(json)));
      if (entry == null || ids.contains(entry.id)) continue;
      if (deleted[entry.id] case final at? when !entry.modifiedAt.isAfter(at)) {
        continue;
      }
      if (cleared.coveredAt(entry) case final at?) {
        covered.add(HistoryTombstone(id: entry.id, deletedAt: at));
      }
    }
    if (covered.isEmpty) return local;
    try {
      await _repository.mergeBackup(
        const [],
        tombstones: covered,
        maxAge: await _retention(),
      );
      final tombstones = (await _repository.backupData()).tombstones;
      return {
        ...local,
        'tombstones': [for (final tombstone in tombstones) tombstone.toJson()],
      };
    } on Object {
      // Not carried back all the same; the next sync tries again.
      return local;
    }
  }

  /// The ids of [local]'s entries.
  static Set<String> _ids(Map<dynamic, dynamic> local) => {
    for (final json in [...?(local['entries'] as List?)])
      if (json is Map && json['id'] is String) json['id'] as String,
  };

  /// [local]'s tombstones: entry id → deleted at.
  static Map<String, DateTime> _deleted(Map<dynamic, dynamic> local) => {
    for (final json in [...?(local['tombstones'] as List?)])
      if (json is Map)
        if (_parsed(() => HistoryTombstone.fromJson(Map.from(json)))
            case final tombstone?)
          tombstone.id: tombstone.deletedAt,
  };

  /// The retention records of a sync file (`retention`) that still count
  /// at [now]: seconds history is kept (null: for ever) → last renewed. A
  /// record renewed more than [HistoryCleared.maxClockSkew] ahead of [now]
  /// is left out, one ahead by less counts as renewed at the start of
  /// [now]'s day (as this device renews its own).
  static Map<int?, DateTime> _records(Object? json, DateTime now) {
    final cutoff = now.subtract(retentionLifetime);
    final latest = now.add(HistoryCleared.maxClockSkew);
    final today = DateTime.utc(now.year, now.month, now.day);
    final records = <int?, DateTime>{};
    if (json is! List) return records;
    for (final record in json) {
      if (record is! Map || !record.containsKey('maxAgeSeconds')) continue;
      final seconds = record['maxAgeSeconds'];
      final parsed = switch (record['seenAt']) {
        final String iso => DateTime.tryParse(iso)?.toUtc(),
        _ => null,
      };
      if ((seconds != null && (seconds is! int || seconds < 0)) ||
          parsed == null ||
          parsed.isBefore(cutoff) ||
          parsed.isAfter(latest)) {
        continue;
      }
      final seenAt = parsed.isAfter(today) ? today : parsed;
      final key = seconds as int?;
      final known = records[key];
      if (known == null || seenAt.isAfter(known)) records[key] = seenAt;
    }
    return records;
  }

  /// The file's [entries] this device doesn't hold because its retention
  /// dropped them (created [before] its cutoff, not favorites, without a
  /// tombstone here, not covered by a clear in [cleared]) and that another
  /// device still keeps (created no earlier than [notBefore]; null: one
  /// keeps them for ever), newest first, as the file has them.
  static List<({DateTime createdAt, Object json})> _carried(
    Object? entries, {
    required Map<dynamic, dynamic> local,
    required HistoryCleared cleared,
    required DateTime before,
    required DateTime? notBefore,
  }) {
    if (entries is! List) return const [];
    final ids = _ids(local);
    final deleted = _deleted(local);
    final carried = <({DateTime createdAt, Object json})>[];
    for (final json in entries) {
      if (json is! Map) continue;
      final entry = _parsed(() => HistoryEntry.fromJson(Map.from(json)));
      if (entry == null || entry.isFavorite || !ids.add(entry.id)) continue;
      if (deleted[entry.id] case final at? when !entry.modifiedAt.isAfter(at)) {
        continue;
      }
      if (!entry.createdAt.isBefore(before)) continue;
      if (cleared.covers(entry)) continue;
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
      return _parse(
        data is _SyncMerge ? data.data : data,
        version,
      ).entries.length;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<int> countLocalItems() async =>
      (await _repository.backupData()).entries.length;

  ({
    List<HistoryEntry> entries,
    List<HistoryTombstone> tombstones,
    HistoryCleared cleared,
  })
  _parse(Object? data, int version) {
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
        cleared: HistoryCleared.fromJson(data['cleared']),
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

/// The sync file's data of the section for a sync merge
/// ([HistoryBackupSection.forSyncMerge]).
class _SyncMerge {
  const new(this.data, this.context);

  final Object? data;
  final SyncMergeContext context;
}
