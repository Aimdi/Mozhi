import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

// The only app file (with lib/platform/mlkit_bindings.dart) that imports ML
// Kit's text recognition. tool/fdroid_prepare.sh deletes it for the F-Droid
// build, so it must not be exported from data.dart or imported elsewhere.

/// Creates a recognizer for a script (overridable for tests).
typedef TextRecognizerFactory = TextRecognizer Function(
  TextRecognitionScript script,
);

/// [TextRecognitionService] backed by Google ML Kit (Android and iOS only).
class MlKitTextRecognitionService implements TextRecognitionService {
  new({
    TextRecognizerFactory? recognizerFactory,
    this._platform,
    this._isWeb = kIsWeb,
  }) : _factory = recognizerFactory ?? _defaultFactory;

  static TextRecognizer _defaultFactory(TextRecognitionScript script) =>
      TextRecognizer(script: script);

  final TextRecognizerFactory _factory;
  final TargetPlatform? _platform;
  final bool _isWeb;

  @override
  bool get isSupported {
    if (_isWeb) return false;
    final platform = _platform ?? defaultTargetPlatform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  @override
  Future<String> recognize(
    PickedImage image, {
    required Language source,
  }) async {
    final path = image.path;
    if (!isSupported || path == null) {
      throw const ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
      );
    }
    final recognizer = _factory(scriptFor(source));
    try {
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );
      return recognized.text.trim();
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
        cause: error,
      );
    } finally {
      try {
        await recognizer.close();
      } on Object {
        // Closing is best effort.
      }
    }
  }

  /// The ML Kit script model for [language] (Latin for auto/unknown).
  static TextRecognitionScript scriptFor(Language language) {
    final code = language.code.toLowerCase().split(RegExp('[-_]')).first;
    return switch (code) {
      'zh' || 'yue' => TextRecognitionScript.chinese,
      'ja' => TextRecognitionScript.japanese,
      'ko' => TextRecognitionScript.korean,
      'hi' ||
      'mr' ||
      'ne' ||
      'sa' ||
      'mai' ||
      'bho' ||
      'kok' => TextRecognitionScript.devanagiri,
      _ => TextRecognitionScript.latin,
    };
  }
}
