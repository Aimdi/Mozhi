import 'package:meta/meta.dart';
import 'package:mozhi_api/src/models/mozhi_word_choice.dart';

/// Result of `/api/translate` for one engine (Go `libmozhi.LangOut`).
///
/// ```json
/// {
///   "engine": "google",
///   "detected": "fr",
///   "translated-text": "Hello",
///   "source_language": "auto",
///   "target_language": "en",
///   "word_choices": [ ... ] | null,
///   "source_transliteration": "",
///   "target_transliteration": "",
///   "source_synonyms": [] | null,
///   "target_synonyms": [] | null,
///   "source_antonyms": [] | null,
///   "target_antonyms": [] | null,
///   "source_equivalent_target_lang": {"word": ["mot"]} | null,
///   "target_equivalent_source_lang": {} | null
/// }
/// ```
/// Every field except `engine` and `translated-text` may be missing, empty
/// or `null`; [MozhiTranslation.fromJson] normalises them to empty values.
@immutable
class MozhiTranslation {
  const new({
    required this.engine,
    required this.translatedText,
    this.detectedLanguage = '',
    this.sourceLanguage = '',
    this.targetLanguage = '',
    this.wordChoices = const [],
    this.sourceTransliteration = '',
    this.targetTransliteration = '',
    this.sourceSynonyms = const [],
    this.targetSynonyms = const [],
    this.sourceAntonyms = const [],
    this.targetAntonyms = const [],
    this.sourceEquivalentTargetLang = const {},
    this.targetEquivalentSourceLang = const {},
  });

  factory fromJson() {
    throw UnimplementedError('TODO(mozhi_api): parse LangOut JSON');
  }

  final String engine;
  final String translatedText;

  /// Language detected by the engine when the source was `auto`.
  final String detectedLanguage;
  final String sourceLanguage;
  final String targetLanguage;
  final List<MozhiWordChoice> wordChoices;
  final String sourceTransliteration;
  final String targetTransliteration;
  final List<String> sourceSynonyms;
  final List<String> targetSynonyms;
  final List<String> sourceAntonyms;
  final List<String> targetAntonyms;
  final Map<String, List<String>> sourceEquivalentTargetLang;
  final Map<String, List<String>> targetEquivalentSourceLang;

  Map<String, dynamic> toJson() {
    throw UnimplementedError('TODO(mozhi_api): serialise LangOut JSON');
  }
}
