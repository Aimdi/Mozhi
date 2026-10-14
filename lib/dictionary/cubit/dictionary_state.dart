import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

enum DictionaryStatus { idle, loading, success, failure }

class DictionaryState extends Equatable {
  const new({
    this.word = '',
    this.source = Language.auto,
    this.target = const Language(code: 'en', name: 'English'),
    this.engine,
    this.verbosity = DictionaryVerbosity.standard,
    this.status = DictionaryStatus.idle,
    this.entry,
    this.lookedUp = '',
    this.error,
  });

  /// What the user is about to look up (the search field).
  final String word;

  /// Language of the word ([Language.auto] lets the model tell).
  final Language source;

  /// Language of the translations and example translations.
  final Language target;

  /// AI engine that writes the entries; null when none is available.
  final TranslationEngine? engine;

  /// How much a look-up asks for (concise, standard or comprehensive).
  final DictionaryVerbosity verbosity;

  final DictionaryStatus status;

  /// The entry for [lookedUp] (when [status] is success).
  final DictionaryEntry? entry;

  /// The word of the latest look-up (the one [entry] or [error] is for).
  final String lookedUp;

  /// Why the latest look-up failed.
  final Object? error;

  bool get hasEngine => engine != null;

  /// A word can be looked up now.
  bool get canLookUp => engine != null && word.trim().isNotEmpty;

  /// The languages can be swapped (not while detecting the source).
  bool get canSwap => !source.isAuto;

  /// The model found nothing to say about [lookedUp].
  bool get isEmptyEntry {
    final entry = this.entry;
    return entry != null &&
        entry.senses.isEmpty &&
        entry.examples.isEmpty &&
        entry.synonyms.isEmpty &&
        entry.etymology.trim().isEmpty &&
        entry.notes.trim().isEmpty;
  }

  DictionaryState copyWith({
    String? word,
    Language? source,
    Language? target,
    TranslationEngine? Function()? engine,
    DictionaryVerbosity? verbosity,
    DictionaryStatus? status,
    DictionaryEntry? Function()? entry,
    String? lookedUp,
    Object? Function()? error,
  }) => DictionaryState(
    word: word ?? this.word,
    source: source ?? this.source,
    target: target ?? this.target,
    engine: engine != null ? engine() : this.engine,
    verbosity: verbosity ?? this.verbosity,
    status: status ?? this.status,
    entry: entry != null ? entry() : this.entry,
    lookedUp: lookedUp ?? this.lookedUp,
    error: error != null ? error() : this.error,
  );

  @override
  List<Object?> get props => [
    word,
    source,
    target,
    engine,
    verbosity,
    status,
    entry,
    lookedUp,
    error,
  ];
}
