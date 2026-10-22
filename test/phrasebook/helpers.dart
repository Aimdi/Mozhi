import 'dart:async';

import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/phrasebook/data/phrasebook_favorites.dart';
import 'package:translation_repository/translation_repository.dart';

const english = Language(code: 'en', name: 'English');
const portuguese = Language(code: 'pt', name: 'Portuguese');

/// A history favourite [id] (`text <id>` → `tradução <id>`).
HistoryEntry favoriteEntry(
  String id, {
  String? text,
  String? translation,
  Language source = english,
  Language target = portuguese,
  DateTime? createdAt,
  HistoryEntryKind kind = HistoryEntryKind.translation,
}) => HistoryEntry(
  id: id,
  text: text ?? 'text $id',
  translation: translation ?? 'tradução $id',
  source: source,
  target: target,
  engineId: 'offline',
  engineName: 'Offline',
  createdAt: createdAt ?? DateTime(2026, 10, 22, 9),
  isFavorite: true,
  kind: kind,
);

/// [PhrasebookFavorites] holding [entries] in memory.
class FakeFavorites implements PhrasebookFavorites {
  new([List<HistoryEntry>? entries]) : entries = [...?entries];

  List<HistoryEntry> entries;
  final removed = <String>[];
  final restored = <String>[];
  final _removedEntries = <String, HistoryEntry>{};
  final StreamController<void> _changes = StreamController.broadcast();

  /// Replaces the favourites and says so.
  void set(List<HistoryEntry> next) {
    entries = [...next];
    _changes.add(null);
  }

  @override
  Future<List<HistoryEntry>> favorites() async => List.unmodifiable(entries);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> remove(String historyId) async {
    removed.add(historyId);
    final entry = entries.where((e) => e.id == historyId).firstOrNull;
    if (entry == null) return;
    _removedEntries[historyId] = entry;
    set([
      for (final e in entries)
        if (e.id != historyId) e,
    ]);
  }

  @override
  Future<void> restore(String historyId) async {
    restored.add(historyId);
    final entry = _removedEntries.remove(historyId);
    if (entry != null) set([entry, ...entries]);
  }
}
