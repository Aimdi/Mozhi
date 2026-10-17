import 'package:equatable/equatable.dart';
import 'package:mozhi/history/models/history_entry.dart';

enum HistoryStatus {
  initial,
  loading,
  ready,

  /// The history could not be read (storage error); retry with `load`.
  failure,

  /// The stored history exists but cannot be decrypted (its key is
  /// missing or does not fit; see `HistoryUnreadableException`). Nothing
  /// is saved until it is loaded again successfully or set aside with
  /// `HistoryCubit.discardUnreadable`.
  unreadable,
}

class HistoryState extends Equatable {
  const new({
    this.status = HistoryStatus.initial,
    this.entries = const [],
    this.query = '',
    this.favoritesOnly = false,
    this.incognito = false,
  });

  final HistoryStatus status;

  /// All entries, newest first.
  final List<HistoryEntry> entries;
  final String query;
  final bool favoritesOnly;

  /// Incognito: new entries are not saved, except favourites
  /// (`HistoryCubit.setIncognito`).
  final bool incognito;

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

  /// How many [entries] a retention of [maxAge] deletes at [now]: the
  /// non-favourites created more than [maxAge] before [now].
  int expiredCount(Duration maxAge, {required DateTime now}) {
    final cutoff = now.subtract(maxAge);
    return entries
        .where((entry) => !entry.isFavorite && entry.createdAt.isBefore(cutoff))
        .length;
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
    bool? incognito,
  }) => HistoryState(
    status: status ?? this.status,
    entries: entries ?? this.entries,
    query: query ?? this.query,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    incognito: incognito ?? this.incognito,
  );

  @override
  List<Object?> get props => [status, entries, query, favoritesOnly, incognito];
}
