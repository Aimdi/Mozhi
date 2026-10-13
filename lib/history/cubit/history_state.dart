import 'package:equatable/equatable.dart';
import 'package:mozhi/history/models/history_entry.dart';

enum HistoryStatus { initial, loading, ready, failure }

class HistoryState extends Equatable {
  const new({
    this.status = HistoryStatus.initial,
    this.entries = const [],
    this.query = '',
    this.favoritesOnly = false,
  });

  final HistoryStatus status;

  /// All entries, newest first.
  final List<HistoryEntry> entries;
  final String query;
  final bool favoritesOnly;

  /// [entries] filtered by [favoritesOnly] and case-insensitive [query]
  /// over text, translation and language names.
  List<HistoryEntry> get visible {
    final needle = query.trim().toLowerCase();
    if (!favoritesOnly && needle.isEmpty) return entries;
    return [
      for (final entry in entries)
        if ((!favoritesOnly || entry.isFavorite) && _matches(entry, needle))
          entry,
    ];
  }

  static bool _matches(HistoryEntry entry, String needle) {
    if (needle.isEmpty) return true;
    return [
      entry.text,
      entry.translation,
      entry.source.name,
      ?entry.source.nativeName,
      entry.target.name,
      ?entry.target.nativeName,
    ].any((field) => field.toLowerCase().contains(needle));
  }

  HistoryState copyWith({
    HistoryStatus? status,
    List<HistoryEntry>? entries,
    String? query,
    bool? favoritesOnly,
  }) => HistoryState(
    status: status ?? this.status,
    entries: entries ?? this.entries,
    query: query ?? this.query,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
  );

  @override
  List<Object?> get props => [status, entries, query, favoritesOnly];
}
