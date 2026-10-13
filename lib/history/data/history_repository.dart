import 'dart:async';
import 'dart:convert';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/history/models/history_entry.dart';

/// Local-only history (JSON list under key `history.v1`), newest first.
/// Keeps at most [maxEntries] non-favourite entries (favourites are never
/// evicted). Adding an entry whose text+target+engine equals the newest
/// entry replaces it instead of duplicating (typing refinements).
///
/// [store] defaults to [PreferencesStore]. Operations are serialised and
/// every mutation is written through; the returned lists are unmodifiable.
/// Invalid stored entries are skipped, unreadable JSON loads as empty.
class HistoryRepository {
  new({KeyValueStore? store, this.maxEntries = 1000})
    : store = store ?? PreferencesStore();

  /// Key of the history JSON in [store].
  static const storageKey = 'history.v1';

  final KeyValueStore store;
  final int maxEntries;

  List<HistoryEntry>? _entries;
  Future<void> _lock = Future.value();

  /// Reads the history from [store] (refreshing the in-memory copy).
  Future<List<HistoryEntry>> load() => _synchronized(() async {
    final raw = await store.read(storageKey);
    final entries = raw == null ? <HistoryEntry>[] : _decodeLenient(raw);
    _entries = _capped(entries);
    return _entries!;
  });

  Future<List<HistoryEntry>> add(HistoryEntry entry) => _mutate((entries) {
    final newest = entries.firstOrNull;
    if (newest != null && _sameRequest(newest, entry)) {
      return [
        entry.copyWith(isFavorite: newest.isFavorite || entry.isFavorite),
        ...entries.skip(1).where((e) => e.id != entry.id),
      ];
    }
    return [entry, ...entries.where((e) => e.id != entry.id)];
  });

  Future<List<HistoryEntry>> toggleFavorite(String id) => _mutate(
    (entries) => [
      for (final entry in entries)
        if (entry.id == id)
          entry.copyWith(isFavorite: !entry.isFavorite)
        else
          entry,
    ],
  );

  Future<List<HistoryEntry>> delete(String id) =>
      _mutate((entries) => entries..removeWhere((e) => e.id == id));

  /// Removes everything, or only non-favourites when [keepFavorites].
  Future<List<HistoryEntry>> clear({bool keepFavorites = false}) => _mutate(
    (entries) =>
        keepFavorites ? entries.where((e) => e.isFavorite).toList() : [],
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
  /// list is sorted newest first and capped like [add]. Invalid elements are
  /// skipped as long as the input is a JSON array with at least one valid
  /// entry (or is empty).
  Future<List<HistoryEntry>> importJson(String json) async {
    final imported = _decodeStrict(json);
    return await _mutate((entries) {
      final ids = {for (final entry in entries) entry.id};
      return [...entries, ...imported.where((e) => ids.add(e.id))]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });
  }

  bool _sameRequest(HistoryEntry a, HistoryEntry b) =>
      a.text.trim() == b.text.trim() &&
      a.target == b.target &&
      a.engineId == b.engineId;

  /// Keeps every favourite and the newest [maxEntries] other entries.
  List<HistoryEntry> _capped(List<HistoryEntry> entries) {
    var others = 0;
    return List.unmodifiable(
      entries.where((e) => e.isFavorite || others++ < maxEntries),
    );
  }

  Future<List<HistoryEntry>> _current() async =>
      _entries ??= _capped(await _readLenient());

  Future<List<HistoryEntry>> _readLenient() async {
    final raw = await store.read(storageKey);
    return raw == null ? [] : _decodeLenient(raw);
  }

  Future<List<HistoryEntry>> _mutate(
    List<HistoryEntry> Function(List<HistoryEntry> entries) change,
  ) => _synchronized(() async {
    final next = _capped(change([...await _current()]));
    await store.write(
      storageKey,
      jsonEncode([for (final entry in next) entry.toJson()]),
    );
    _entries = next;
    return next;
  });

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
