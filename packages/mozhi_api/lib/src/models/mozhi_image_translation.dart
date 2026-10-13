import 'package:meta/meta.dart';

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

  factory fromJson() {
    throw UnimplementedError('TODO(mozhi_api): parse ImgOut JSON');
  }

  final String translatedImageBase64;
  final String sourceImageBase64;
  final String sourceLanguage;
  final String targetLanguage;
  final String sourceText;
  final String translatedText;
}
