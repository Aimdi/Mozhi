import 'package:meta/meta.dart';

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

  TranslationResult copyWith({
    String? text,
    bool? isComplete,
    String? detectedSource,
    Duration? elapsed,
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
  );
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
}
