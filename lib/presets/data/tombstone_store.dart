import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/presets/models/tombstone.dart';

/// The tombstones ([Tombstone]) of the presets or of the glossaries:
/// `{"<id>": <deleted at, milliseconds since the epoch>}` under [key] in
/// [store], next to the data they belong to (plain JSON like it: presets
/// and glossaries are not encrypted).
///
/// Tombstones older than [maxAge] are dropped, and at most the newest
/// [maxCount] are kept. Nothing is cached: the app's repository and the
/// backup sections' (each its own instance over the same store) always
/// see the same tombstones.
class TombstoneStore {
  const new({
    required this.store,
    required this.key,
    required this.maxCount,
    required this.maxAge,
    required this._clock,
  });

  final KeyValueStore store;

  /// Where the tombstones are stored in [store].
  final String key;

  /// At most this many tombstones are kept (the newest).
  final int maxCount;

  /// Tombstones older than this are dropped.
  final Duration maxAge;

  final DateTime Function() _clock;

  /// How often a write that failed for a full quota is retried (each time
  /// with the older half dropped).
  static const _quotaRetries = 4;

  /// The stored tombstones (id → deleted at, UTC) within the bounds. Empty
  /// when there are none or they are unreadable; throws when the store
  /// fails.
  Future<Map<String, DateTime>> read() async {
    final raw = await store.read(key);
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw);
      return bounded({
        if (json is Map)
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && key.isNotEmpty && value is int)
              key: DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
      });
    } on FormatException {
      // Damaged: the next change writes them anew.
      return {};
    }
  }

  /// Records [deleted] ids as deleted now and drops the tombstones of the
  /// [present] ids, writing only when that changes something. Never
  /// throws: tombstones are best effort, the change they follow has been
  /// written.
  Future<void> update({
    Iterable<String> deleted = const [],
    Iterable<String> present = const [],
  }) async {
    try {
      final tombstones = await read();
      var changed = false;
      final now = _clock().toUtc();
      for (final id in deleted) {
        tombstones[id] = now;
        changed = true;
      }
      for (final id in present) {
        if (tombstones.remove(id) != null) changed = true;
      }
      if (changed) await _write(tombstones);
    } on Object {
      // Kept as they were; a deleted item may come back from another copy.
    }
  }

  /// Replaces the stored tombstones with [tombstones], without those of
  /// the [present] ids. Never throws, like [update].
  Future<void> replace(
    Map<String, DateTime> tombstones, {
    Iterable<String> present = const [],
  }) async {
    try {
      final next = {...tombstones};
      present.forEach(next.remove);
      await _write(next);
    } on Object {
      // Best effort, like update.
    }
  }

  /// [tombstones] without those older than [maxAge], at most the newest
  /// [maxCount].
  Map<String, DateTime> bounded(Map<String, DateTime> tombstones) {
    final cutoff = _clock().subtract(maxAge);
    final recent = {
      for (final MapEntry(:key, :value) in tombstones.entries)
        if (!value.isBefore(cutoff)) key: value,
    };
    return recent.length <= maxCount ? recent : _newest(recent, maxCount);
  }

  /// [tombstones] as a list (for a backup).
  static List<Tombstone> toList(Map<String, DateTime> tombstones) =>
      List.unmodifiable([
        for (final MapEntry(:key, :value) in tombstones.entries)
          Tombstone(id: key, deletedAt: value),
      ]);

  /// [tombstones] as a map, the latest per id (UTC).
  static Map<String, DateTime> toMap(Iterable<Tombstone> tombstones) {
    final result = <String, DateTime>{};
    for (final Tombstone(:id, :deletedAt) in tombstones) {
      final known = result[id];
      if (known == null || deletedAt.isAfter(known)) {
        result[id] = deletedAt.toUtc();
      }
    }
    return result;
  }

  /// Writes [tombstones], bounded (deletes the stored value when none are
  /// left): on a full quota, the older half is dropped and the write
  /// retried.
  Future<void> _write(Map<String, DateTime> tombstones) async {
    var next = bounded(tombstones);
    for (var attempt = 0; ; attempt++) {
      if (next.isEmpty) {
        await store.delete(key);
        return;
      }
      try {
        await store.write(
          key,
          jsonEncode({
            for (final MapEntry(:key, :value) in next.entries)
              key: value.millisecondsSinceEpoch,
          }),
        );
        return;
      } on Object catch (error) {
        if (attempt >= _quotaRetries || !_isQuotaError(error)) rethrow;
        next = _newest(next, next.length ~/ 2);
      }
    }
  }

  static Map<String, DateTime> _newest(
    Map<String, DateTime> tombstones,
    int count,
  ) {
    final sorted = tombstones.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(sorted.take(count));
  }

  /// Whether [error] reports a full storage quota (e.g. the browser's
  /// `QuotaExceededError` from `localStorage`).
  static bool _isQuotaError(Object error) =>
      error.toString().toLowerCase().contains('quota');
}
