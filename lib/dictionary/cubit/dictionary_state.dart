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
    this.entryLanguage,
    this.offlineAnswer,
    this.offlineLanguages = const [],
    this.suggestions = const [],
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

  /// Code of the language of the shown [entry] (e.g. for reading it
  /// aloud): the chosen [source], else the language identified on the
  /// device once the entry arrived; null while unknown.
  final String? entryLanguage;

  /// What an offline dictionary had for [lookedUp] when it wrote [entry]
  /// (its language, the credit of its data, the lemma of an inflected
  /// form); null for an entry written by the AI [engine].
  final OfflineDictionaryAnswer? offlineAnswer;

  /// Language codes of the installed offline dictionaries.
  final List<String> offlineLanguages;

  /// Words of the offline dictionaries that start like [lookedUp], when
  /// nothing was found (and no AI engine could look it up).
  final List<String> suggestions;

  bool get hasEngine => engine != null;

  /// Whether offline dictionaries are installed: look-ups use them first.
  bool get hasOfflineDictionaries => offlineLanguages.isNotEmpty;

  /// Whether an installed offline dictionary has the words of [language]
  /// (any, to detect the language).
  bool hasOfflineDictionaryFor(Language language) => language.isAuto
      ? hasOfflineDictionaries
      : offlineLanguages.any(
          (code) => dictionaryLanguageMatches(code, language.code),
        );

  /// A word can be looked up now (with AI, or in an offline dictionary).
  bool get canLookUp =>
      (engine != null || hasOfflineDictionaries) && word.trim().isNotEmpty;

  /// The shown (or loading) entry comes from an offline dictionary.
  bool get isOfflineEntry => offlineAnswer != null;

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
    String? Function()? entryLanguage,
    OfflineDictionaryAnswer? Function()? offlineAnswer,
    List<String>? offlineLanguages,
    List<String>? suggestions,
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
    entryLanguage: entryLanguage != null ? entryLanguage() : this.entryLanguage,
    offlineAnswer: offlineAnswer != null ? offlineAnswer() : this.offlineAnswer,
    offlineLanguages: offlineLanguages ?? this.offlineLanguages,
    suggestions: suggestions ?? this.suggestions,
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
    entryLanguage,
    offlineAnswer,
    offlineLanguages,
    suggestions,
  ];
}
