import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

/// On-device text recognition (injectable for tests).
abstract interface class TextRecognitionService {
  /// Whether recognition works on this platform.
  bool get isSupported;

  /// Returns the text found in [image] (empty when there is none). [source]
  /// picks the script model. Throws [ImageTranslateException]
  /// (`recognitionFailed`) on failure.
  Future<String> recognize(PickedImage image, {required Language source});
}

/// On-device text recognition that reads with language data downloaded
/// per language on request: the default build's Tesseract
/// (`TesseractTextRecognitionService`). ML Kit (Play variant) bundles its
/// models and does not implement it; see [textRecognitionLanguageDataOf].
///
/// Nothing here downloads by itself: only [downloadOcrLanguage] does,
/// when the user asks.
abstract interface class TextRecognitionLanguageData {
  /// Whether recognition (and so its language data) works here.
  bool get isSupported;

  /// Every language with downloadable data, sorted by code.
  Future<List<OcrLanguage>> ocrLanguages();

  /// The data that reads the app language [code] (`de`, `zh-TW`, `pt-BR`;
  /// regions are ignored), or null when there is none.
  Future<OcrLanguage?> ocrLanguageFor(String code);

  /// Bytes on the device per installed language code.
  Future<Map<String, int>> installedOcrLanguages();

  /// Recognises [image] with [codes] (installed languages, main one
  /// first). Throws [OcrDataMissingException] when one is not installed,
  /// [ImageTranslateException] (`invalidImage`, `recognitionFailed`) on
  /// failure.
  Future<String> recognizeWith(PickedImage image, List<String> codes);

  /// Downloads the data of [code]. With [wifiOnly], a metered network
  /// fails with `MeteredConnectionException` before anything is sent.
  /// [onProgress] gets the fraction received (0 to 1).
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  });

  /// Deletes the data of [code].
  Future<void> deleteOcrLanguage(String code);

  /// Installs data from files the user copied to the device ([paths]),
  /// without the network.
  Future<OcrImportReport> importOcrFiles(List<String> paths);

  /// Fires after installed data changed (download, import, deletion).
  Stream<void> get ocrLanguagesChanged;
}

/// Text recognised in an image, with how sure the recognizer is.
@immutable
class TextWithConfidence {
  const new(this.text, {this.confidence});

  final String text;

  /// 0 to 100 (Tesseract's mean word confidence), null when unknown.
  final int? confidence;

  @override
  bool operator ==(Object other) =>
      other is TextWithConfidence &&
      other.text == text &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(text, confidence);

  @override
  String toString() => 'TextWithConfidence(${text.length} chars, $confidence%)';
}

/// [TextRecognitionLanguageData] that also says how sure it is of what it
/// read (Tesseract). A low confidence for "Detect language" usually means
/// the text is in a language whose data was not used.
abstract interface class TextRecognitionConfidence {
  /// Like [TextRecognitionLanguageData.recognizeWith], with the confidence.
  Future<TextWithConfidence> recognizeWithConfidence(
    PickedImage image,
    List<String> codes,
  );
}

/// [service]'s language data, when it downloads data per language (the
/// default build); null for ML Kit and for no recognizer at all.
TextRecognitionLanguageData? textRecognitionLanguageDataOf(
  TextRecognitionService service,
) => switch (service) {
  final TextRecognitionLanguageData data => data,
  _ => null,
};

/// [TextRecognitionService] for builds without an on-device recognizer
/// (the web app): never supported, and [recognize] always fails with
/// `recognitionFailed`.
class UnavailableTextRecognitionService implements TextRecognitionService {
  const new();

  @override
  bool get isSupported => false;

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      Future.error(
        const ImageTranslateException(
          ImageTranslateErrorKind.recognitionFailed,
        ),
      );
}
