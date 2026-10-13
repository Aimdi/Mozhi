import 'package:meta/meta.dart';
import 'package:mozhi_api/src/models/json_readers.dart';

/// Result of `POST /api/image` (Go `libmozhi.ImgOut`, no JSON tags):
/// `{"SourceB64": "...", "TranslatedImgB64": "...", "SourceLang": "auto",
///   "TargetLang": "en", "SourceTextParsed": "...",
///   "TranslatedTextParsed": "..."}`.
@immutable
class MozhiImageTranslation {
  const new({
    required this.translatedImageBase64,
    this.sourceImageBase64 = '',
    this.sourceLanguage = '',
    this.targetLanguage = '',
    this.sourceText = '',
    this.translatedText = '',
  });

  /// Missing or `null` fields become empty strings.
  factory fromJson(Map<String, dynamic> json) => MozhiImageTranslation(
    translatedImageBase64: readString(json['TranslatedImgB64']),
    sourceImageBase64: readString(json['SourceB64']),
    sourceLanguage: readString(json['SourceLang']),
    targetLanguage: readString(json['TargetLang']),
    sourceText: readString(json['SourceTextParsed']),
    translatedText: readString(json['TranslatedTextParsed']),
  );

  final String translatedImageBase64;
  final String sourceImageBase64;
  final String sourceLanguage;
  final String targetLanguage;
  final String sourceText;
  final String translatedText;
}
