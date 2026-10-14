import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/models/history_entry.dart';

/// Local-only history (JSON list under key `history.v1`), newest first.
///
/// Size limits (favourites are never evicted):
/// * at most [maxEntries] non-favourite entries;
/// * the stored JSON stays within [maxStoredLength] UTF-16 code units by
///   evicting the oldest non-favourites (preferences share one quota with
///   the settings, e.g. browser `localStorage` on the web);
/// * `text` and `translation` longer than [maxTextLength] are truncated
///   (ending with `…`) when added.
///
/// When the store reports a full quota on a write, older non-favourites
/// are evicted and the write is retried.
///
/// [add] merges with the newest entry instead of duplicating it when both
/// have the same source, target and engine and either
/// * the trimmed texts are equal, unless the newest entry is a favourite
///   with a different translation (a starred translation is never
///   overwritten), or
/// * the newest entry is not a favourite, was created within
///   [refinementWindow] and one trimmed text is a prefix of the other
///   (typing refinements of instant translate).
///
/// Retention (history auto-delete): [load], [add] and [importJson] take an
/// optional `maxAge` and then also drop non-favourite entries created more
/// than `maxAge` ago; [prune] applies a (new) `maxAge` right away.
/// Favourites are always kept. [load] writes the pruned history back when
/// it dropped expired entries.
///
/// [toggleFavorite], [delete], [clear] and [restore] apply no caps (and no
/// retention), so an un-starred or restored entry survives until the next
/// [add] / [load].
///
/// [store] defaults to [PreferencesStore] and `clock` (the current time for
/// retention) to [DateTime.now]. Operations are serialised and
/// every mutation is written through; the returned lists are unmodifiable.
/// Invalid stored entries are skipped, unreadable JSON loads as empty.
class HistoryRepository {
  new({
    KeyValueStore? store,
    this.maxEntries = 1000,
    this.maxStoredLength = 1000000,
    this.maxTextLength = 20000,
    this.refinementWindow = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : assert(maxTextLength > 0, 'maxTextLength must be positive'),
       store = store ?? PreferencesStore(),
       _clock = clock ?? DateTime.now;

  /// Key of the history JSON in [store].
  static const storageKey = 'history.v1';

  /// How often a write that failed for a full quota is retried (each time
  /// with the older half of the non-favourites evicted).
  static const _quotaRetries = 4;

  final KeyValueStore store;
  final int maxEntries;

  /// Maximum length (UTF-16 code units) of the stored JSON; only
  /// favourites may exceed it.
  final int maxStoredLength;

  /// Maximum stored length of an entry's `text` and `translation` each.
  final int maxTextLength;

  /// How far apart in time an entry may be from the newest one to be
  /// treated as a typing refinement of it (see [add]).
  final Duration refinementWindow;

  final DateTime Function() _clock;

  List<HistoryEntry>? _entries;
  Future<void> _lock = Future.value();

  /// Encoded JSON per entry (entries are immutable).
  final Expando<String> _encoded = Expando();

  /// Reads the history from [store] (refreshing the in-memory copy).
  ///
  /// With [maxAge], non-favourites created more than [maxAge] ago are
  /// dropped and, if there were any, the result is written back (a failing
  /// write is ignored: the next mutation writes again).
  Future<List<HistoryEntry>> load({Duration? maxAge}) =>
      _synchronized(() async {
        final raw = await store.read(storageKey);
        final entries = raw == null ? <HistoryEntry>[] : _decodeLenient(raw);
        final kept = _withoutExpired(entries, maxAge);
        var next = _capped(kept);
        if (kept.length != entries.length) {
          try {
            next = await _write(next);
          } on Object {
            // Keep the pruned list in memory; the next mutation writes it.
          }
        }
        return _entries = next;
      });

  /// Deletes non-favourite entries created more than [maxAge] ago (none
  /// when [maxAge] is null) and returns the history. Writes only when
  /// something was deleted.
  Future<List<HistoryEntry>> prune(Duration? maxAge) =>
      _synchronized(() async {
        final entries = await _current();
        final kept = _withoutExpired(entries, maxAge);
        if (kept.length == entries.length) return entries;
        return _entries = await _write(List.unmodifiable(kept));
      });

  /// Inserts [entry] as the newest entry (see the class docs for merging
  /// with the newest entry, truncation, caps and [maxAge]). An existing
  /// entry with the same id is removed.
  Future<List<HistoryEntry>> add(HistoryEntry entry, {Duration? maxAge}) {
    final added = _limited(entry);
    return _mutate(maxAge: maxAge, (entries) {
      final newest = entries.firstOrNull;
      if (newest != null && _replaces(newest, added)) {
        return [
          added.copyWith(isFavorite: newest.isFavorite || added.isFavorite),
          ...entries.skip(1).where((e) => e.id != added.id),
        ];
      }
      return [added, ...entries.where((e) => e.id != added.id)];
    });
  }

  /// Puts [entry] back, e.g. to undo [delete]: it is inserted at the
  /// position of its [HistoryEntry.createdAt] (before the first older
  /// entry) and replaces only an entry with the same id. Unlike [add] it
  /// never merges with the newest entry and applies no caps.
  Future<List<HistoryEntry>> restore(HistoryEntry entry) {
    final restored = _limited(entry);
    return _mutate((entries) {
      final others = entries.where((e) => e.id != restored.id).toList();
      final index = others.indexWhere(
        (e) => e.createdAt.isBefore(restored.createdAt),
      );
      return others..insert(index == -1 ? others.length : index, restored);
    }, cap: false);
  }

  Future<List<HistoryEntry>> toggleFavorite(String id) => _mutate(
    (entries) => [
      for (final entry in entries)
        if (entry.id == id)
          entry.copyWith(isFavorite: !entry.isFavorite)
        else
          entry,
    ],
    cap: false,
  );

  Future<List<HistoryEntry>> delete(String id) =>
      _mutate((entries) => entries..removeWhere((e) => e.id == id), cap: false);

  /// Removes everything, or only non-favourites when [keepFavorites].
  Future<List<HistoryEntry>> clear({bool keepFavorites = false}) => _mutate(
    (entries) =>
        keepFavorites ? entries.where((e) => e.isFavorite).toList() : [],
    cap: false,
  );

  /// Pretty JSON array of all entries.
  Future<String> exportJson() => _synchronized(() async {
    final entries = await _current();
    return const JsonEncoder.withIndent('  ')
        .convert([for (final entry in entries) entry.toJson()]);
  });

  /// Merges entries from [json] (dedupe by id); returns the new list.
  /// Throws [FormatException] on invalid input.
  ///
  /// Existing entries win over imported ones with the same id; the merged
  /// list is sorted newest first, truncated and capped like [add] (with
  /// [maxAge], expired non-favourites are dropped too). Invalid elements
  /// are skipped as long as the input is a JSON array with at least one
  /// valid entry (or is empty).
  Future<List<HistoryEntry>> importJson(String json, {Duration? maxAge}) async {
    final imported = _decodeStrict(json).map(_limited).toList();
    return await _mutate(maxAge: maxAge, (entries) {
      final ids = {for (final entry in entries) entry.id};
      return [...entries, ...imported.where((e) => ids.add(e.id))]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });
  }

  /// Whether [entry] should replace [newest] instead of being inserted.
  bool _replaces(HistoryEntry newest, HistoryEntry entry) {
    if (newest.engineId != entry.engineId ||
        newest.source != entry.source ||
        newest.target != entry.target) {
      return false;
    }
    final previous = newest.text.trim();
    final text = entry.text.trim();
    if (previous == text) {
      return !newest.isFavorite ||
          newest.translation.trim() == entry.translation.trim();
    }
    return !newest.isFavorite &&
        previous.isNotEmpty &&
        text.isNotEmpty &&
        (text.startsWith(previous) || previous.startsWith(text)) &&
        entry.createdAt.difference(newest.createdAt).abs() <= refinementWindow;
  }

  /// [entry] with `text` and `translation` truncated to [maxTextLength].
  HistoryEntry _limited(HistoryEntry entry) {
    final text = _truncated(entry.text);
    final translation = _truncated(entry.translation);
    if (identical(text, entry.text) &&
        identical(translation, entry.translation)) {
      return entry;
    }
    return entry.copyWith(text: text, translation: translation);
  }

  String _truncated(String value) {
    if (value.length <= maxTextLength) return value;
    var end = maxTextLength - 1;
    // Do not split a surrogate pair.
    if (end > 0 && _isHighSurrogate(value.codeUnitAt(end - 1))) end--;
    return '${value.substring(0, end)}…';
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  /// [entries] without the non-favourites created more than [maxAge] ago.
  List<HistoryEntry> _withoutExpired(
    List<HistoryEntry> entries,
    Duration? maxAge,
  ) {
    if (maxAge == null) return entries;
    final cutoff = _clock().subtract(maxAge);
    return [
      for (final entry in entries)
        if (entry.isFavorite || !entry.createdAt.isBefore(cutoff)) entry,
    ];
  }

  /// Keeps every favourite and the newest non-favourites within
  /// [maxEntries] and [maxStoredLength].
  List<HistoryEntry> _capped(List<HistoryEntry> entries) {
    // The JSON array: brackets plus (at most) one separator per entry.
    var left = maxStoredLength - 2;
    for (final entry in entries) {
      if (entry.isFavorite) left -= _json(entry).length + 1;
    }
    var others = 0;
    var full = false;
    final kept = <HistoryEntry>[];
    for (final entry in entries) {
      if (entry.isFavorite) {
        kept.add(entry);
        continue;
      }
      if (full || others >= maxEntries) continue;
      final length = _json(entry).length + 1;
      if (length > left) {
        // Evict this entry and every older non-favourite.
        full = true;
        continue;
      }
      left -= length;
      others++;
      kept.add(entry);
    }
    return List.unmodifiable(kept);
  }

  /// [entries] without the older half of the non-favourites (rounded up,
  /// so a single one is evicted too).
  static List<HistoryEntry> _withoutOlderHalf(List<HistoryEntry> entries) {
    var keep = entries.where((e) => !e.isFavorite).length ~/ 2;
    return List.unmodifiable(entries.where((e) => e.isFavorite || keep-- > 0));
  }

  String _json(HistoryEntry entry) =>
      _encoded[entry] ??= jsonEncode(entry.toJson());

  /// Same output as `jsonEncode` of the entries' JSON list.
  String _encode(List<HistoryEntry> entries) =>
      '[${entries.map(_json).join(',')}]';

  Future<List<HistoryEntry>> _current() async =>
      _entries ??= _capped(await _readLenient());

  Future<List<HistoryEntry>> _readLenient() async {
    final raw = await store.read(storageKey);
    return raw == null ? [] : _decodeLenient(raw);
  }

  Future<List<HistoryEntry>> _mutate(
    List<HistoryEntry> Function(List<HistoryEntry> entries) change, {
    bool cap = true,
    Duration? maxAge,
  }) => _synchronized(() async {
    final changed = change([...await _current()]);
    final next = cap
        ? _capped(_withoutExpired(changed, maxAge))
        : List<HistoryEntry>.unmodifiable(changed);
    return _entries = await _write(next);
  });

  /// Writes [entries] and returns what was written: on a full quota, older
  /// non-favourites are evicted and the write is retried.
  Future<List<HistoryEntry>> _write(List<HistoryEntry> entries) async {
    var next = entries;
    for (var attempt = 0; ; attempt++) {
      final encoded = _encode(next);
      try {
        await store.write(storageKey, encoded);
        return next;
      } on Object catch (error) {
        if (attempt >= _quotaRetries || !_isQuotaError(error)) rethrow;
        final smaller = _withoutOlderHalf(next);
        if (smaller.length == next.length) rethrow;
        next = smaller;
      }
    }
  }

  /// Whether [error] reports a full storage quota (e.g. the browser's
  /// `QuotaExceededError` from `localStorage`).
  static bool _isQuotaError(Object error) {
    try {
      return error.toString().toLowerCase().contains('quota');
    } on Object {
      return false;
    }
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static List<HistoryEntry> _decodeLenient(String raw) {
    try {
      final json = jsonDecode(raw);
      return json is List ? _parseEntries(json) : [];
    } on FormatException {
      return [];
    }
  }

  static List<HistoryEntry> _decodeStrict(String raw) {
    final json = jsonDecode(raw);
    if (json is! List) {
      throw const FormatException('Expected a JSON array of history entries');
    }
    final entries = _parseEntries(json);
    if (entries.isEmpty && json.isNotEmpty) {
      throw const FormatException('No valid history entries found');
    }
    return entries;
  }

  static List<HistoryEntry> _parseEntries(List<dynamic> json) => [
    for (final element in json)
      if (element is Map) ?_tryParse(element),
  ];

  static HistoryEntry? _tryParse(Map<dynamic, dynamic> json) {
    try {
      return HistoryEntry.fromJson(Map<String, dynamic>.from(json));
    } on Object {
      return null;
    }
  }
}
