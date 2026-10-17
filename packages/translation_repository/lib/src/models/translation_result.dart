import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/src/models/data_destination.dart';

const _list = ListEquality<Object?>();

/// Dictionary data for one word (from Mozhi `word_choices`).
@immutable
class WordChoice {
  const new({
    required this.word,
    this.definition = '',
    this.examplesSource = const [],
    this.examplesTarget = const [],
  });

  final String word;
  final String definition;
  final List<String> examplesSource;
  final List<String> examplesTarget;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WordChoice &&
          other.word == word &&
          other.definition == definition &&
          _list.equals(other.examplesSource, examplesSource) &&
          _list.equals(other.examplesTarget, examplesTarget);

  @override
  int get hashCode => Object.hash(
    word,
    definition,
    _list.hash(examplesSource),
    _list.hash(examplesTarget),
  );
}

/// One (possibly partial, while streaming) translation.
@immutable
class TranslationResult {
  const new({
    required this.engineId,
    required this.engineName,
    required this.text,
    this.isComplete = true,
    this.detectedSource,
    this.sourceTransliteration = '',
    this.targetTransliteration = '',
    this.wordChoices = const [],
    this.sourceSynonyms = const [],
    this.targetSynonyms = const [],
    this.elapsed,
    this.fromCache = false,
    this.detectionUncertain = false,
    this.detectedAlternatives = const [],
    this.destination,
  });

  final String engineId;
  final String engineName;
  final String text;

  /// False for intermediate streaming snapshots (AI engines).
  final bool isComplete;

  /// Language code detected when the source was auto (normalised to a
  /// `LanguageCatalog` code where possible), else null.
  final String? detectedSource;
  final String sourceTransliteration;
  final String targetTransliteration;
  final List<WordChoice> wordChoices;
  final List<String> sourceSynonyms;
  final List<String> targetSynonyms;

  /// Wall time from request start to this snapshot.
  final Duration? elapsed;

  /// Whether this result was served from the translation cache rather
  /// than by a new request to the engine (nothing was sent or billed).
  final bool fromCache;

  /// Whether the detected source language of a short input (source auto)
  /// may be wrong: a second detection was unsure or disagreed with
  /// [detectedSource]. False when nothing was checked.
  final bool detectionUncertain;

  /// When [detectionUncertain]: up to 3 other languages the input may be
  /// in (codes, most likely first; the user's recent source languages are
  /// preferred). Never contains [detectedSource].
  final List<String> detectedAlternatives;

  /// Where the text was sent to produce this result (set by
  /// `TranslationRepository` for every result: the Mozhi instance that
  /// actually answered after a failover; a cached result keeps the
  /// destination it was produced with). Null for results built elsewhere.
  final DataDestination? destination;

  TranslationResult copyWith({
    String? text,
    bool? isComplete,
    String? detectedSource,
    Duration? elapsed,
    bool? fromCache,
    bool? detectionUncertain,
    List<String>? detectedAlternatives,
    DataDestination? destination,
  }) => TranslationResult(
    engineId: engineId,
    engineName: engineName,
    text: text ?? this.text,
    isComplete: isComplete ?? this.isComplete,
    detectedSource: detectedSource ?? this.detectedSource,
    sourceTransliteration: sourceTransliteration,
    targetTransliteration: targetTransliteration,
    wordChoices: wordChoices,
    sourceSynonyms: sourceSynonyms,
    targetSynonyms: targetSynonyms,
    elapsed: elapsed ?? this.elapsed,
    fromCache: fromCache ?? this.fromCache,
    detectionUncertain: detectionUncertain ?? this.detectionUncertain,
    detectedAlternatives: detectedAlternatives ?? this.detectedAlternatives,
    destination: destination ?? this.destination,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TranslationResult &&
          other.engineId == engineId &&
          other.engineName == engineName &&
          other.text == text &&
          other.isComplete == isComplete &&
          other.detectedSource == detectedSource &&
          other.sourceTransliteration == sourceTransliteration &&
          other.targetTransliteration == targetTransliteration &&
          _list.equals(other.wordChoices, wordChoices) &&
          _list.equals(other.sourceSynonyms, sourceSynonyms) &&
          _list.equals(other.targetSynonyms, targetSynonyms) &&
          other.elapsed == elapsed &&
          other.fromCache == fromCache &&
          other.detectionUncertain == detectionUncertain &&
          _list.equals(other.detectedAlternatives, detectedAlternatives) &&
          other.destination == destination;

  @override
  int get hashCode => Object.hash(
    engineId,
    engineName,
    text,
    isComplete,
    detectedSource,
    sourceTransliteration,
    targetTransliteration,
    _list.hash(wordChoices),
    _list.hash(sourceSynonyms),
    _list.hash(targetSynonyms),
    elapsed,
    fromCache,
    detectionUncertain,
    _list.hash(detectedAlternatives),
    destination,
  );

  @override
  String toString() =>
      'TranslationResult($engineId, complete: $isComplete, '
      'detected: $detectedSource'
      '${detectionUncertain ? ' (uncertain: $detectedAlternatives)' : ''}'
      '${fromCache ? ', cached' : ''}'
      '${destination == null ? '' : ', to: $destination'}, text: $text)';
}

/// A result (or failure) from compare mode.
@immutable
class CompareEntry {
  const new success(this.result)
    : engineId = null,
      engineName = null,
      error = null;
  const new failure({
    required String this.engineId,
    required String this.engineName,
    required Object this.error,
  }) : result = null;

  final TranslationResult? result;
  final String? engineId;
  final String? engineName;
  final Object? error;

  bool get isSuccess => result != null;
  String get id => result?.engineId ?? engineId!;
  String get name => result?.engineName ?? engineName!;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompareEntry &&
          other.result == result &&
          other.engineId == engineId &&
          other.engineName == engineName &&
          other.error == error;

  @override
  int get hashCode => Object.hash(result, engineId, engineName, error);
}
