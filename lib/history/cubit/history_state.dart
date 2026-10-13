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
  List<HistoryEntry> get visible => throw UnimplementedError();

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
