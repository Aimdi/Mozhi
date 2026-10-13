import 'package:mozhi/history/models/history_entry.dart';

/// Local-only history (JSON list under key `history.v1`), newest first.
/// Keeps at most [maxEntries] non-favourite entries (favourites are never
/// evicted). Adding an entry whose text+target+engine equals the newest
/// entry replaces it instead of duplicating (typing refinements).
class HistoryRepository {
  new({this.maxEntries = 1000});

  final int maxEntries;

  Future<List<HistoryEntry>> load() => throw UnimplementedError();
  Future<List<HistoryEntry>> add(HistoryEntry entry) =>
      throw UnimplementedError();
  Future<List<HistoryEntry>> toggleFavorite(String id) =>
      throw UnimplementedError();
  Future<List<HistoryEntry>> delete(String id) => throw UnimplementedError();

  /// Removes everything, or only non-favourites when [keepFavorites].
  Future<List<HistoryEntry>> clear({bool keepFavorites = false}) =>
      throw UnimplementedError();

  /// Pretty JSON array of all entries.
  Future<String> exportJson() => throw UnimplementedError();

  /// Merges entries from [json] (dedupe by id); returns the new list.
  /// Throws [FormatException] on invalid input.
  Future<List<HistoryEntry>> importJson(String json) =>
      throw UnimplementedError();
}
