import 'package:meta/meta.dart';
import 'package:mt_api/src/json_readers.dart';

/// Values for the `format` parameter of LibreTranslate's `/translate`.
abstract final class LibreFormat {
  static const String text = 'text';
  static const String html = 'html';

  static const List<String> values = [text, html];
}

/// A detected language: `{"confidence": 90.0, "language": "fr"}`.
///
/// [confidence] is a percentage in `[0, 100]`.
@immutable
class LibreDetectedLanguage {
  const new({required this.code, required this.confidence});

  factory fromJson(Map<String, dynamic> json) => LibreDetectedLanguage(
    code: readString(json['language']),
    confidence: readDouble(json['confidence']),
  );

  /// LibreTranslate code (`en`, `zh-Hans`, `pb`, ...).
  final String code;
  final double confidence;

  Map<String, dynamic> toJson() => {'language': code, 'confidence': confidence};

  @override
  bool operator ==(Object other) =>
      other is LibreDetectedLanguage &&
      other.code == code &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(code, confidence);

  @override
  String toString() => 'LibreDetectedLanguage($code, $confidence)';
}

/// The result of `POST /translate` for one text.
///
/// JSON: `{"translatedText": "Hello", "detectedLanguage": {...},
/// "alternatives": ["Hi"]}`; `detectedLanguage` is only sent for
/// `source: auto`, `alternatives` only when requested.
@immutable
class LibreTranslation {
  const new({
    required this.text,
    this.detectedLanguage,
    this.alternatives = const [],
  });

  factory fromJson(Map<String, dynamic> json) => LibreTranslation(
    text: readString(json['translatedText']),
    detectedLanguage: switch (json['detectedLanguage']) {
      final Map<String, dynamic> detected => LibreDetectedLanguage.fromJson(
        detected,
      ),
      _ => null,
    },
    alternatives: readStringList(json['alternatives']),
  );

  final String text;
  final LibreDetectedLanguage? detectedLanguage;
  final List<String> alternatives;

  Map<String, dynamic> toJson() => {
    'translatedText': text,
    if (detectedLanguage case final detected?)
      'detectedLanguage': detected.toJson(),
    if (alternatives.isNotEmpty) 'alternatives': alternatives,
  };

  @override
  bool operator ==(Object other) =>
      other is LibreTranslation &&
      other.text == text &&
      other.detectedLanguage == detectedLanguage &&
      listEquals(other.alternatives, alternatives);

  @override
  int get hashCode =>
      Object.hash(text, detectedLanguage, Object.hashAll(alternatives));

  @override
  String toString() => 'LibreTranslation($text)';
}

/// An entry of `GET /languages`:
/// `{"code": "en", "name": "English", "targets": ["ar", "de", ...]}`.
@immutable
class LibreLanguage {
  const new({required this.code, required this.name, this.targets = const []});

  factory fromJson(Map<String, dynamic> json) => LibreLanguage(
    code: readString(json['code']),
    name: readString(json['name']),
    targets: readStringList(json['targets']),
  );

  final String code;
  final String name;

  /// Codes this language can be translated into (older servers omit it).
  final List<String> targets;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'targets': targets,
  };

  @override
  bool operator ==(Object other) =>
      other is LibreLanguage &&
      other.code == code &&
      other.name == name &&
      listEquals(other.targets, targets);

  @override
  int get hashCode => Object.hash(code, name, Object.hashAll(targets));

  @override
  String toString() => 'LibreLanguage($code, $name)';
}

/// `GET /frontend/settings`: what a server allows.
///
/// JSON: `{"apiKeys": true, "charLimit": 5000, "keyRequired": false,
/// "suggestions": false, "filesTranslation": true,
/// "supportedFilesFormat": [".txt", ...], ...}`.
@immutable
class LibreSettings {
  const new({
    this.apiKeys = false,
    this.keyRequired = false,
    this.charLimit,
    this.suggestions = false,
    this.filesTranslation = false,
    this.supportedFilesFormat = const [],
  });

  factory fromJson(Map<String, dynamic> json) => LibreSettings(
    apiKeys: readBool(json['apiKeys']),
    keyRequired: readBool(json['keyRequired']),
    charLimit: switch (json['charLimit']) {
      final num limit when limit > 0 => limit.toInt(),
      _ => null,
    },
    suggestions: readBool(json['suggestions']),
    filesTranslation: readBool(json['filesTranslation']),
    supportedFilesFormat: readStringList(json['supportedFilesFormat']),
  );

  /// Whether the server has API keys enabled at all.
  final bool apiKeys;

  /// Whether every request needs an API key.
  final bool keyRequired;

  /// Maximum characters per request; `null` when unlimited (`-1`).
  final int? charLimit;
  final bool suggestions;
  final bool filesTranslation;
  final List<String> supportedFilesFormat;

  Map<String, dynamic> toJson() => {
    'apiKeys': apiKeys,
    'keyRequired': keyRequired,
    'charLimit': charLimit ?? -1,
    'suggestions': suggestions,
    'filesTranslation': filesTranslation,
    'supportedFilesFormat': supportedFilesFormat,
  };

  @override
  bool operator ==(Object other) =>
      other is LibreSettings &&
      other.apiKeys == apiKeys &&
      other.keyRequired == keyRequired &&
      other.charLimit == charLimit &&
      other.suggestions == suggestions &&
      other.filesTranslation == filesTranslation &&
      listEquals(other.supportedFilesFormat, supportedFilesFormat);

  @override
  int get hashCode => Object.hash(
    apiKeys,
    keyRequired,
    charLimit,
    suggestions,
    filesTranslation,
    Object.hashAll(supportedFilesFormat),
  );

  @override
  String toString() =>
      'LibreSettings(keyRequired: $keyRequired, charLimit: $charLimit)';
}
