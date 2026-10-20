import 'package:equatable/equatable.dart';
import 'package:mozhi/history/cubit/history_filters.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

export 'history_filters.dart';

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
    this.saveHistory = true,
    this.pair,
    this.destination,
  });

  final HistoryStatus status;

  /// All entries, newest first.
  final List<HistoryEntry> entries;
  final String query;
  final bool favoritesOnly;

  /// Incognito: new entries are not saved, except favourites
  /// (`HistoryCubit.setIncognito`).
  final bool incognito;

  /// Whether history is saved ("Save history",
  /// `HistoryCubit.setSaveHistory`): when off, as in [incognito], only
  /// favourites are.
  final bool saveHistory;

  /// Whether history is paused ([incognito], or [saveHistory] off): only
  /// favourites are saved, and kept only as long as they are favourites
  /// ([HistoryEntry.favoriteOnly]).
  bool get paused => incognito || !saveHistory;

  /// Only entries of this language pair (null: all).
  final HistoryPair? pair;

  /// Only entries whose text went there (null: anywhere).
  final HistoryDestination? destination;

  /// Whether the [pair] or [destination] filter is set.
  bool get hasFilters => pair != null || destination != null;

  /// [entries] filtered by [favoritesOnly], [pair], [destination] (with the
  /// default [historyDestinationOf]) and case-insensitive [query] over
  /// text, translation and language names (for dictionary look-ups: the
  /// word and its summary).
  List<HistoryEntry> get visible => visibleWith(historyDestinationOf);

  /// Like [visible], classifying entries for the [destination] filter with
  /// [destinationOf] (e.g. [historyDestinationOf] with the configured
  /// instances and providers).
  List<HistoryEntry> visibleWith(HistoryDestinationOf destinationOf) {
    final needle = query.trim().toLowerCase();
    if (!favoritesOnly && needle.isEmpty && !hasFilters) return entries;
    final pair = this.pair;
    final destination = this.destination;
    return [
      for (final entry in entries)
        if ((!favoritesOnly || entry.isFavorite) &&
            (pair == null || pair.matches(entry)) &&
            (destination == null ||
                destinationOf(entry.engineId) == destination) &&
            _matches(entry, needle))
          entry,
    ];
  }

  /// The dictionary look-up of [word] from [source] into [target] in
  /// [entries] ([HistoryEntry.isLookUpOf]), or null.
  HistoryEntry? lookUpOf(
    String word, {
    required Language source,
    required Language target,
  }) => entries
      .where((entry) => entry.isLookUpOf(word, source: source, target: target))
      .firstOrNull;

  /// Whether [entries] holds dictionary look-ups.
  bool get hasLookUps => entries.any((entry) => entry.isDictionary);

  /// The language pairs of [entries] with how many entries each has, most
  /// used first.
  List<(HistoryPair, int)> get pairs {
    final counts = <HistoryPair, int>{};
    for (final entry in entries) {
      final pair = HistoryPair.of(entry);
      counts[pair] = (counts[pair] ?? 0) + 1;
    }
    return [for (final MapEntry(:key, :value) in counts.entries) (key, value)]
      ..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// The destinations [entries] went to, classified with [destinationOf],
  /// in [HistoryDestination] order.
  List<HistoryDestination> destinationsWith(
    HistoryDestinationOf destinationOf,
  ) {
    final found = {for (final entry in entries) ?destinationOf(entry.engineId)};
    return [
      for (final destination in HistoryDestination.values)
        if (found.contains(destination)) destination,
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
    bool? saveHistory,
    HistoryPair? Function()? pair,
    HistoryDestination? Function()? destination,
  }) => HistoryState(
    status: status ?? this.status,
    entries: entries ?? this.entries,
    query: query ?? this.query,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    incognito: incognito ?? this.incognito,
    saveHistory: saveHistory ?? this.saveHistory,
    pair: pair != null ? pair() : this.pair,
    destination: destination != null ? destination() : this.destination,
  );

  @override
  List<Object?> get props => [
    status,
    entries,
    query,
    favoritesOnly,
    incognito,
    saveHistory,
    pair,
    destination,
  ];
}
