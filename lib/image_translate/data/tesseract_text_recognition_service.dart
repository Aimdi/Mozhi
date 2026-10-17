import 'dart:async';
import 'dart:io' show File;

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:mozhi/image_translate/data/rgba_image_decoder.dart';
import 'package:mozhi/image_translate/data/text_recognition_plan.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';
import 'package:translation_repository/translation_repository.dart';

/// On-device text recognition of the default build: Tesseract
/// (`packages/tesseract_ocr`, no Google code) with tessdata_fast language
/// data downloaded per language on request.
///
/// `open` creates the engine on first use (it loads the bundled catalog;
/// `lib/platform/text_recognition_io.dart` passes the app's), so creating
/// this service is free. [recognize] (the [TextRecognitionService]
/// contract) reads with the source's data, or with the installed
/// languages for "Detect language" (see [planTextRecognition]); the image
/// screen plans with the user's preferred languages and calls
/// [recognizeWith]. Pixels are decoded with a [RgbaImageDecoder]
/// (`dart:ui`). Downloads honour Wi-Fi only through
/// `isMeteredConnection`.
class TesseractTextRecognitionService
    implements TextRecognitionService, TextRecognitionLanguageData {
  new({
    required this._open,
    required this.isSupported,
    required Future<bool> Function() isMeteredConnection,
    this._decoder = const UiRgbaImageDecoder(),
  }) : _isMetered = isMeteredConnection;

  final Future<TesseractOcr> Function() _open;
  final Future<bool> Function() _isMetered;
  final RgbaImageDecoder _decoder;
  final _changes = StreamController<void>.broadcast();
  Future<TesseractOcr>? _ocr;
  List<OcrLanguage>? _languages;

  @override
  final bool isSupported;

  @override
  Stream<void> get ocrLanguagesChanged => _changes.stream;

  @override
  Future<List<OcrLanguage>> ocrLanguages() async =>
      _languages ??= List.unmodifiable([
        for (final language in (await _engine()).catalog.languages)
          _describe(language),
      ]);

  @override
  Future<OcrLanguage?> ocrLanguageFor(String code) async {
    if (code.trim().isEmpty || code == Language.auto.code) return null;
    final ocr = await _engine();
    final language =
        ocr.catalog.forAppLanguage(code) ??
        ocr.catalog.forAppLanguage(LanguageMatcher.normalize(code));
    return language == null ? null : _describe(language);
  }

  @override
  Future<Map<String, int>> installedOcrLanguages() async {
    final ocr = await _engine();
    return {
      for (final installed in await ocr.data.installed())
        if (ocr.catalog.byCode(installed.code) != null)
          installed.code: installed.sizeBytes,
    };
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
    return switch (await planTextRecognition(this, source: source)) {
      TextRecognitionReady(:final codes) => await recognizeWith(image, codes),
      TextRecognitionNeedsData(:final missing) => throw missing,
      TextRecognitionUnsupported() => throw const ImageTranslateException(
        ImageTranslateErrorKind.recognitionLanguageUnsupported,
      ),
    };
  }

  @override
  Future<String> recognizeWith(PickedImage image, List<String> codes) async {
    final ocr = await _engine();
    final decoded = await _decoder.decode(image.bytes);
    try {
      final result = await ocr.recognize(
        decoded.pixels,
        decoded.width,
        decoded.height,
        languages: codes,
      );
      return result.text;
    } on TessdataMissingException catch (error) {
      final language = ocr.catalog.byCode(error.missing.first);
      if (language == null) rethrow;
      throw OcrDataMissingException(_describe(language));
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
        cause: error,
      );
    }
  }

  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    final ocr = await _engine();
    if (wifiOnly && await _isMetered()) {
      throw const MeteredConnectionException();
    }
    await ocr.download(
      code,
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(progress.fraction),
    );
    _changes.add(null);
  }

  @override
  Future<void> deleteOcrLanguage(String code) async {
    await (await _engine()).delete(code);
    _changes.add(null);
  }

  @override
  Future<OcrImportReport> importOcrFiles(List<String> paths) async {
    final result = await (await _engine()).importFiles([
      for (final path in paths) File(path),
    ]);
    List<String> codes(TessdataImportStatus status) => [
      for (final outcome in result.languages)
        if (outcome.status == status) outcome.language.code,
    ];
    final report = OcrImportReport(
      installed: codes(TessdataImportStatus.installed),
      alreadyInstalled: codes(TessdataImportStatus.alreadyInstalled),
      damaged: codes(TessdataImportStatus.checksumMismatch),
      failed: codes(TessdataImportStatus.failed),
      unmatchedFiles: [
        for (final file in result.unmatched) file.uri.pathSegments.last,
      ],
    );
    if (report.installed.isNotEmpty) _changes.add(null);
    return report;
  }

  /// The engine, created once (a failed start is retried next time).
  Future<TesseractOcr> _engine() {
    final existing = _ocr;
    if (existing != null) return existing;
    final started = _open();
    _ocr = started;
    unawaited(
      started.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_ocr, started)) _ocr = null;
        },
      ),
    );
    return started;
  }

  static OcrLanguage _describe(TessdataLanguage language) => OcrLanguage(
    code: language.code,
    appCode: language.languages.first,
    downloadSize: language.size,
    url: language.url,
  );
}
