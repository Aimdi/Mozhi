import 'package:meta/meta.dart';
import 'package:mt_api/src/json_readers.dart';

/// Values for the `formality` parameter of `DeeplClient.translate`.
///
/// `more`/`less` make DeepL reject target languages without formality
/// support (HTTP 400); the `prefer*` variants silently fall back to the
/// default instead, so apps should normally send those.
abstract final class DeeplFormality {
  static const String standard = 'default';
  static const String more = 'more';
  static const String less = 'less';
  static const String preferMore = 'prefer_more';
  static const String preferLess = 'prefer_less';

  static const List<String> values = [
    standard,
    more,
    less,
    preferMore,
    preferLess,
  ];
}

/// Values for the `tag_handling` parameter.
abstract final class DeeplTagHandling {
  static const String html = 'html';
  static const String xml = 'xml';

  static const List<String> values = [html, xml];
}

/// Values for the `model_type` parameter.
abstract final class DeeplModelType {
  static const String qualityOptimized = 'quality_optimized';
  static const String preferQualityOptimized = 'prefer_quality_optimized';
  static const String latencyOptimized = 'latency_optimized';

  static const List<String> values = [
    qualityOptimized,
    preferQualityOptimized,
    latencyOptimized,
  ];
}

/// Which list `GET /v2/languages` returns.
enum DeeplLanguageType { source, target }

/// One translated text from `POST /v2/translate`.
///
/// JSON: `{"detected_source_language": "EN", "text": "Hallo",
/// "billed_characters": 5, "model_type_used": "quality_optimized"}`.
@immutable
class DeeplTranslation {
  const new({
    required this.text,
    required this.detectedSourceLanguage,
    this.billedCharacters,
    this.modelTypeUsed,
  });

  factory fromJson(Map<String, dynamic> json) => DeeplTranslation(
    text: readString(json['text']),
    detectedSourceLanguage: readString(json['detected_source_language']),
    billedCharacters: json['billed_characters'] is num
        ? readInt(json['billed_characters'])
        : null,
    modelTypeUsed: readOptionalString(json['model_type_used']),
  );

  final String text;

  /// DeepL source code (`EN`, `DE`, `ZH`, ...), also when the source
  /// language was given. Empty if the server omitted it.
  final String detectedSourceLanguage;

  /// Only present when `show_billed_characters` was requested.
  final int? billedCharacters;

  /// Only present when a `model_type` was requested.
  final String? modelTypeUsed;

  Map<String, dynamic> toJson() => {
    'text': text,
    'detected_source_language': detectedSourceLanguage,
    'billed_characters': ?billedCharacters,
    'model_type_used': ?modelTypeUsed,
  };

  @override
  bool operator ==(Object other) =>
      other is DeeplTranslation &&
      other.text == text &&
      other.detectedSourceLanguage == detectedSourceLanguage &&
      other.billedCharacters == billedCharacters &&
      other.modelTypeUsed == modelTypeUsed;

  @override
  int get hashCode => Object.hash(
    text,
    detectedSourceLanguage,
    billedCharacters,
    modelTypeUsed,
  );

  @override
  String toString() => 'DeeplTranslation($detectedSourceLanguage: $text)';
}

/// An entry of `GET /v2/languages`.
///
/// JSON: `{"language": "EN-US", "name": "English (American)",
/// "supports_formality": false}` (`supports_formality` only for targets).
@immutable
class DeeplLanguage {
  const new({
    required this.code,
    required this.name,
    this.supportsFormality = false,
  });

  factory fromJson(Map<String, dynamic> json) => DeeplLanguage(
    code: readString(json['language']),
    name: readString(json['name']),
    supportsFormality: readBool(json['supports_formality']),
  );

  /// DeepL code as the server spells it (`DE`, `EN-GB`, `ZH-HANS`).
  final String code;
  final String name;
  final bool supportsFormality;

  Map<String, dynamic> toJson() => {
    'language': code,
    'name': name,
    'supports_formality': supportsFormality,
  };

  @override
  bool operator ==(Object other) =>
      other is DeeplLanguage &&
      other.code == code &&
      other.name == name &&
      other.supportsFormality == supportsFormality;

  @override
  int get hashCode => Object.hash(code, name, supportsFormality);

  @override
  String toString() => 'DeeplLanguage($code, $name)';
}

/// `GET /v2/usage`: `{"character_count": 180118,
/// "character_limit": 1250000}`.
@immutable
class DeeplUsage {
  const new({required this.characterCount, required this.characterLimit});

  factory fromJson(Map<String, dynamic> json) => DeeplUsage(
    characterCount: readInt(json['character_count']),
    characterLimit: readInt(json['character_limit']),
  );

  /// Characters translated in the current billing period.
  final int characterCount;

  /// Maximum for the period; `0` when the account reports no limit.
  /// Pro accounts without a cost control limit report a huge number
  /// (`1000000000000`).
  final int characterLimit;

  bool get hasLimit => characterLimit > 0;

  /// Characters left this period (never negative); `null` without a limit.
  int? get remaining => hasLimit
      ? (characterLimit - characterCount).clamp(0, characterLimit)
      : null;

  /// Used share of the limit in `[0, 1]`; `null` without a limit.
  double? get usedFraction =>
      hasLimit ? (characterCount / characterLimit).clamp(0, 1) : null;

  bool get isQuotaExceeded => hasLimit && characterCount >= characterLimit;

  Map<String, dynamic> toJson() => {
    'character_count': characterCount,
    'character_limit': characterLimit,
  };

  @override
  bool operator ==(Object other) =>
      other is DeeplUsage &&
      other.characterCount == characterCount &&
      other.characterLimit == characterLimit;

  @override
  int get hashCode => Object.hash(characterCount, characterLimit);

  @override
  String toString() => 'DeeplUsage($characterCount / $characterLimit)';
}

/// A v2 glossary (one language pair).
///
/// JSON: `{"glossary_id": "def3a26b-...", "name": "My Glossary",
/// "ready": true, "source_lang": "en", "target_lang": "de",
/// "creation_time": "2021-08-03T14:16:18.329Z", "entry_count": 1}`.
@immutable
class DeeplGlossary {
  const new({
    required this.id,
    required this.name,
    required this.sourceLang,
    required this.targetLang,
    this.ready = true,
    this.creationTime,
    this.entryCount = 0,
  });

  factory fromJson(Map<String, dynamic> json) => DeeplGlossary(
    id: readString(json['glossary_id']),
    name: readString(json['name']),
    sourceLang: readString(json['source_lang']),
    targetLang: readString(json['target_lang']),
    ready: json['ready'] != false,
    creationTime: readDateTime(json['creation_time']),
    entryCount: readInt(json['entry_count']),
  );

  final String id;
  final String name;

  /// Lowercase base codes (`en`, `de`).
  final String sourceLang;
  final String targetLang;
  final bool ready;
  final DateTime? creationTime;
  final int entryCount;

  Map<String, dynamic> toJson() => {
    'glossary_id': id,
    'name': name,
    'ready': ready,
    'source_lang': sourceLang,
    'target_lang': targetLang,
    if (creationTime case final time?) 'creation_time': time.toIso8601String(),
    'entry_count': entryCount,
  };

  @override
  bool operator ==(Object other) =>
      other is DeeplGlossary &&
      other.id == id &&
      other.name == name &&
      other.sourceLang == sourceLang &&
      other.targetLang == targetLang &&
      other.ready == ready &&
      other.creationTime == creationTime &&
      other.entryCount == entryCount;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    sourceLang,
    targetLang,
    ready,
    creationTime,
    entryCount,
  );

  @override
  String toString() =>
      'DeeplGlossary($id, $name, $sourceLang->$targetLang, $entryCount)';
}

/// An entry of `GET /v2/glossary-language-pairs`:
/// `{"source_lang": "de", "target_lang": "en"}`.
@immutable
class DeeplGlossaryLanguagePair {
  const new({required this.sourceLang, required this.targetLang});

  factory fromJson(Map<String, dynamic> json) => DeeplGlossaryLanguagePair(
    sourceLang: readString(json['source_lang']),
    targetLang: readString(json['target_lang']),
  );

  final String sourceLang;
  final String targetLang;

  Map<String, dynamic> toJson() => {
    'source_lang': sourceLang,
    'target_lang': targetLang,
  };

  @override
  bool operator ==(Object other) =>
      other is DeeplGlossaryLanguagePair &&
      other.sourceLang == sourceLang &&
      other.targetLang == targetLang;

  @override
  int get hashCode => Object.hash(sourceLang, targetLang);

  @override
  String toString() => 'DeeplGlossaryLanguagePair($sourceLang->$targetLang)';
}
