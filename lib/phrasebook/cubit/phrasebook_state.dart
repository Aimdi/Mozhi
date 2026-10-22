import 'package:equatable/equatable.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/phrasebook/models/phrase_collection.dart';

/// Where the phrasebook screen is.
enum PhrasebookStatus {
  loading,
  ready,

  /// The stored phrasebook cannot be decrypted
  /// (`PhrasebookUnreadableException`); nothing is saved until it is set
  /// aside (`PhrasebookCubit.discardUnreadable`).
  unreadable,

  /// It could not be read (a storage error); `load` tries again.
  failure,
}

/// How a collection's phrases are listed.
enum PhraseSort {
  /// The newest first (a starter phrasebook: the page's order, by section).
  recent,

  /// By the phrase, A to Z.
  alphabetical,
}

/// The language pair of phrases, as a filter.
class PhrasePair extends Equatable {
  const new(this.sourceCode, this.targetCode);

  /// [phrase]'s pair.
  factory of(Phrase phrase) => PhrasePair(phrase.sourceCode, phrase.targetCode);

  final String sourceCode;
  final String targetCode;

  bool matches(Phrase phrase) =>
      phrase.sourceCode == sourceCode && phrase.targetCode == targetCode;

  @override
  List<Object?> get props => [sourceCode, targetCode];
}

class PhrasebookState extends Equatable {
  const new({
    this.status = PhrasebookStatus.loading,
    this.collections = const [],
    this.phrases = const {},
    this.selectedId,
    this.query = '',
    this.pair,
    this.sort = PhraseSort.recent,
  });

  final PhrasebookStatus status;

  /// Every collection, as `PhrasebookRepository.collections` lists them.
  final List<PhraseCollection> collections;

  /// Every phrase by id.
  final Map<String, Phrase> phrases;

  /// The collection shown (null: the list of collections, on phones).
  final String? selectedId;

  /// Filters the shown collection's phrases (text, translation, note and
  /// pronunciation; ignoring case).
  final String query;

  /// Only phrases of this pair (null: all).
  final PhrasePair? pair;
  final PhraseSort sort;

  /// The shown collection, if it still exists.
  PhraseCollection? get selected =>
      collections.where((c) => c.id == selectedId).firstOrNull;

  /// The user's collections (without Favorites and starter phrasebooks).
  List<PhraseCollection> get userCollections =>
      collections.where((c) => c.isEditable).toList();

  /// The installed starter phrasebooks.
  List<PhraseCollection> get starterCollections =>
      collections.where((c) => c.starter).toList();

  /// The Favorites collection.
  PhraseCollection? get favorites =>
      collections.where((c) => c.isFavorites).firstOrNull;

  /// [collection]'s phrases in its order.
  List<Phrase> phrasesOf(PhraseCollection collection) => [
    for (final id in collection.phraseIds) ?phrases[id],
  ];

  /// The language pairs of [collection]'s phrases with how many each has,
  /// most first.
  List<(PhrasePair, int)> pairsOf(PhraseCollection collection) {
    final counts = <PhrasePair, int>{};
    for (final phrase in phrasesOf(collection)) {
      final pair = PhrasePair.of(phrase);
      counts[pair] = (counts[pair] ?? 0) + 1;
    }
    return [for (final MapEntry(:key, :value) in counts.entries) (key, value)]
      ..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// The shown collection's phrases, filtered by [query] and [pair] and
  /// sorted by [sort]: the newest first (the Favorites as the history
  /// lists them; a starter phrasebook in its page's order), or A to Z.
  List<Phrase> get visible {
    final collection = selected;
    if (collection == null) return const [];
    final all = phrasesOf(collection);
    final needle = query.trim().toLowerCase();
    final pair = this.pair;
    final shown = [
      for (final phrase in all)
        if ((pair == null || pair.matches(phrase)) && _matches(phrase, needle))
          phrase,
    ];
    switch (sort) {
      case PhraseSort.recent:
        // Favorites are newest first already; collections keep the order
        // phrases were added in.
        if (collection.isEditable) return shown.reversed.toList();
        return shown;
      case PhraseSort.alphabetical:
        return shown..sort(
          (a, b) => a.text.toLowerCase().compareTo(b.text.toLowerCase()),
        );
    }
  }

  /// Whether a search or the pair filter is set.
  bool get hasFilters => query.trim().isNotEmpty || pair != null;

  static bool _matches(Phrase phrase, String needle) {
    if (needle.isEmpty) return true;
    return [
      phrase.text,
      phrase.translation,
      phrase.note,
      phrase.pronunciation,
    ].any((field) => field.toLowerCase().contains(needle));
  }

  PhrasebookState copyWith({
    PhrasebookStatus? status,
    List<PhraseCollection>? collections,
    Map<String, Phrase>? phrases,
    String? Function()? selectedId,
    String? query,
    PhrasePair? Function()? pair,
    PhraseSort? sort,
  }) => PhrasebookState(
    status: status ?? this.status,
    collections: collections ?? this.collections,
    phrases: phrases ?? this.phrases,
    selectedId: selectedId != null ? selectedId() : this.selectedId,
    query: query ?? this.query,
    pair: pair != null ? pair() : this.pair,
    sort: sort ?? this.sort,
  );

  @override
  List<Object?> get props => [
    status,
    collections,
    phrases,
    selectedId,
    query,
    pair,
    sort,
  ];
}
