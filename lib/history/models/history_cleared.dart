import 'package:equatable/equatable.dart';
import 'package:mozhi/history/models/history_entry.dart';

/// When **Clear history** last ran, on this device or on one it synced
/// with: [all] for a clear of everything, [nonFavorites] for one that kept
/// the favourites.
///
/// A clear deletes what the device holds and leaves tombstones for it
/// (`HistoryTombstone`), but the other devices of a sync folder may hold
/// entries this one never had (e.g. older than its "Delete history
/// automatically"). The sync file carries this record so that the devices
/// that synced with that folder at the time drop what the clear would have
/// dropped ([covers]): entries created and last changed at or before the
/// clear, keeping the favourites for [nonFavorites]. An entry changed or
/// created later (on any device) is kept. A device that started syncing
/// after the clear ([HistorySyncMerge.joinedAt]), and a device restoring a
/// backup or taking data from another phone, keeps its own entries
/// (`HistoryRepository.mergeBackup`).
class HistoryCleared extends Equatable {
  const new({this.all, this.nonFavorites});

  /// Parses [toJson] output leniently: a missing or invalid time is left
  /// out (so anything else reads as [none]).
  factory fromJson(Object? json) {
    if (json is! Map) return none;
    DateTime? time(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toUtc() : null;
    return HistoryCleared(
      all: time(json['all']),
      nonFavorites: time(json['nonFavorites']),
    );
  }

  /// No clear recorded.
  static const none = HistoryCleared();

  /// How far ahead of this device's clock a recorded clear may be and still
  /// count (as now, see [validAt]): a device whose clock is wrong by more
  /// than that would otherwise delete everything created until then.
  static const maxClockSkew = Duration(days: 1);

  /// When everything was cleared (favourites too).
  final DateTime? all;

  /// When everything but the favourites was cleared.
  final DateTime? nonFavorites;

  /// Whether no clear is recorded.
  bool get isEmpty => all == null && nonFavorites == null;

  /// Whether a recorded clear removes [entry] (it was created and last
  /// changed at or before it, and for [nonFavorites] is not a favourite).
  bool covers(HistoryEntry entry) => coveredAt(entry) != null;

  /// The time of the clear that removes [entry] (the later one when both
  /// do), or null when none does (see [covers]).
  DateTime? coveredAt(HistoryEntry entry) {
    bool before(DateTime? at) =>
        at != null &&
        !entry.createdAt.isAfter(at) &&
        !entry.modifiedAt.isAfter(at);
    final byAll = before(all) ? all : null;
    final byNonFavorites = !entry.isFavorite && before(nonFavorites)
        ? nonFavorites
        : null;
    return _later(byAll, byNonFavorites);
  }

  /// Whether one of the recorded clears was at [at] (to the millisecond:
  /// the time of the tombstones a clear leaves).
  bool isClearTime(DateTime at) => [all, nonFavorites].any(
    (time) =>
        time != null &&
        time.millisecondsSinceEpoch == at.millisecondsSinceEpoch,
  );

  /// Both records: the later clear of each kind.
  HistoryCleared union(HistoryCleared other) => HistoryCleared(
    all: _later(all, other.all),
    nonFavorites: _later(nonFavorites, other.nonFavorites),
  );

  /// The clears at or after [joinedAt] (all of them for null: a device that
  /// synced before them, or since before join times were recorded).
  HistoryCleared since(DateTime? joinedAt) {
    if (joinedAt == null) return this;
    DateTime? kept(DateTime? at) =>
        at == null || at.isBefore(joinedAt) ? null : at;
    return HistoryCleared(all: kept(all), nonFavorites: kept(nonFavorites));
  }

  /// The clears before [joinedAt] (none for null), see [since].
  HistoryCleared before(DateTime? joinedAt) {
    if (joinedAt == null) return none;
    DateTime? kept(DateTime? at) =>
        at != null && at.isBefore(joinedAt) ? at : null;
    return HistoryCleared(all: kept(all), nonFavorites: kept(nonFavorites));
  }

  /// This record as a device whose clock says [now] trusts it: a clear
  /// more than [maxClockSkew] ahead (a wrong clock) is left out, one ahead
  /// by less counts as [now].
  HistoryCleared validAt(DateTime now) {
    DateTime? trusted(DateTime? at) {
      if (at == null || !at.isAfter(now)) return at;
      return at.isAfter(now.add(maxClockSkew)) ? null : now.toUtc();
    }

    return HistoryCleared(
      all: trusted(all),
      nonFavorites: trusted(nonFavorites),
    );
  }

  /// `{"all": "…Z", "nonFavorites": "…Z"}` (UTC; a time not recorded is
  /// left out).
  Map<String, dynamic> toJson() => {
    if (all case final at?) 'all': at.toUtc().toIso8601String(),
    if (nonFavorites case final at?)
      'nonFavorites': at.toUtc().toIso8601String(),
  };

  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b?.toUtc();
    if (b == null) return a.toUtc();
    return (b.isAfter(a) ? b : a).toUtc();
  }

  @override
  List<Object?> get props => [
    all?.microsecondsSinceEpoch,
    nonFavorites?.microsecondsSinceEpoch,
  ];
}

/// A merge of the sync file's history (`HistoryRepository.mergeBackup`):
/// its record of clears [cleared], on a device that has synced with that
/// folder since [joinedAt] (null: unknown, as for a device that synced
/// before join times were recorded; it counts as syncing all along).
class HistorySyncMerge extends Equatable {
  const new({this.cleared = HistoryCleared.none, this.joinedAt});

  final HistoryCleared cleared;
  final DateTime? joinedAt;

  @override
  List<Object?> get props => [cleared, joinedAt?.microsecondsSinceEpoch];
}
