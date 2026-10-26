import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:translation_repository/translation_repository.dart';

// Play variant only (tool/play_prepare.sh copies it to
// lib/image_translate/data/): the only app file, with the Play bindings in
// lib/platform/mlkit_bindings.dart, that imports ML Kit's text recognition.
// The default (Google-free) build has neither, so it must not be exported
// from data.dart or imported anywhere else.

/// Creates a recognizer for a script (overridable for tests).
typedef TextRecognizerFactory = TextRecognizer Function(
  TextRecognitionScript script,
);

/// Writes [bytes] (an encoded image) to a new private temporary file and
/// returns its path (overridable for tests).
typedef TemporaryImageWriter = Future<String> Function(Uint8List bytes);

/// [TextRecognitionService] backed by Google ML Kit (Android and iOS only).
///
/// ML Kit reads files: an image without a path (a screenshot, a still of
/// the live camera) is written to the app's private cache for the reading
/// and deleted right after.
class MlKitTextRecognitionService implements TextRecognitionService {
  new({
    TextRecognizerFactory? recognizerFactory,
    TemporaryImageWriter? temporaryImageWriter,
    this._platform,
    this._isWeb = kIsWeb,
  }) : _factory = recognizerFactory ?? _defaultFactory,
       _writeTemporary = temporaryImageWriter ?? _defaultTemporaryImageWriter;

  static TextRecognizer _defaultFactory(TextRecognitionScript script) =>
      TextRecognizer(script: script);

  // coverage:ignore-start
  static Future<String> _defaultTemporaryImageWriter(Uint8List bytes) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/mlkit_${DateTime.now().microsecondsSinceEpoch}.img',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
  // coverage:ignore-end

  final TextRecognizerFactory _factory;
  final TemporaryImageWriter _writeTemporary;
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
    if (!isSupported) {
      throw const ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
      );
    }
    String? temporary;
    final String path;
    try {
      path = image.path ?? (temporary = await _writeTemporary(image.bytes));
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
        cause: error,
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
      if (temporary != null) await _delete(temporary);
    }
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on Object {
      // Already gone, or the cache is cleared at the next start anyway.
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
