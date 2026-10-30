import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// What the offline dictionaries said about the word.
enum WordLookupStatus {
  /// Looking it up in the installed dictionaries.
  loading,

  /// An installed dictionary has it ([WordLookupState.offlineAnswer]).
  found,

  /// The installed dictionaries of the word's language don't have it.
  notFound,

  /// No dictionary of the word's language is installed.
  noDictionary,
}

/// The look-up the user asked a dictionary engine for.
enum WordLookupOnlineStatus {
  /// Not asked for.
  idle,

  /// Waiting for the engine.
  loading,

  /// The engine's entry is [WordLookupState.onlineEntry].
  done,

  /// It failed or the privacy settings stopped it
  /// ([WordLookupState.error], e.g. a `ConsentRequiredException`).
  failure,
}

class WordLookupState extends Equatable {
  const new({
    required this.word,
    required this.language,
    this.into,
    this.sentence = '',
    this.engine,
    this.status = WordLookupStatus.loading,
    this.offlineAnswer,
    this.onlineStatus = WordLookupOnlineStatus.idle,
    this.onlineEntry,
    this.error,
  });

  /// The word looked up.
  final String word;

  /// Its language.
  final Language language;

  /// The language of the translations (the other side of the
  /// translation), when known.
  final Language? into;

  /// The sentence the word is in, sent with an explicit look-up.
  final String sentence;

  /// The dictionary engine an explicit look-up goes to ("Look up with
  /// …"); null when there is none.
  final TranslationEngine? engine;

  final WordLookupStatus status;

  /// The installed dictionaries' entry (when [status] is found).
  final OfflineDictionaryAnswer? offlineAnswer;

  final WordLookupOnlineStatus onlineStatus;

  /// The engine's entry (when [onlineStatus] is done).
  final DictionaryEntry? onlineEntry;

  /// Why the explicit look-up failed.
  final Object? error;

  /// The entry shown: the engine's once the user asked for it, else the
  /// offline dictionaries'.
  DictionaryEntry? get entry => onlineEntry ?? offlineAnswer?.entry;

  /// Whether [entry] was written by the engine (an AI model).
  bool get isOnlineEntry => onlineEntry != null;

  /// Whether "Look up with …" is offered: there is an engine, the offline
  /// look-up is over and the engine was not asked yet (or failed).
  bool get canLookUpOnline =>
      engine != null &&
      status != WordLookupStatus.loading &&
      (onlineStatus == WordLookupOnlineStatus.idle ||
          onlineStatus == WordLookupOnlineStatus.failure);

  /// The engine's entry or the offline one has nothing to show.
  bool get isEmptyEntry {
    final entry = this.entry;
    return entry == null ||
        (entry.senses.isEmpty &&
            entry.examples.isEmpty &&
            entry.synonyms.isEmpty);
  }

  WordLookupState copyWith({
    String? word,
    WordLookupStatus? status,
    OfflineDictionaryAnswer? Function()? offlineAnswer,
    WordLookupOnlineStatus? onlineStatus,
    DictionaryEntry? Function()? onlineEntry,
    Object? Function()? error,
  }) => WordLookupState(
    word: word ?? this.word,
    language: language,
    into: into,
    sentence: sentence,
    engine: engine,
    status: status ?? this.status,
    offlineAnswer: offlineAnswer != null ? offlineAnswer() : this.offlineAnswer,
    onlineStatus: onlineStatus ?? this.onlineStatus,
    onlineEntry: onlineEntry != null ? onlineEntry() : this.onlineEntry,
    error: error != null ? error() : this.error,
  );

  @override
  List<Object?> get props => [
    word,
    language,
    into,
    sentence,
    engine,
    status,
    offlineAnswer,
    onlineStatus,
    onlineEntry,
    error,
  ];
}
