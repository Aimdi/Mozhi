import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Color, Rect;

import 'package:bergamot_translator/bergamot_translator.dart'
    show MeteredConnectionException;
import 'package:mozhi/image_translate/data/rgba_image_decoder.dart';
import 'package:mozhi/image_translate/data/text_recognition_plan.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/settings/models/model_source.dart';
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
/// [recognizeWithConfidence], which also reports where each paragraph is
/// ([textLayoutOf]). Pixels are decoded with a [RgbaImageDecoder]
/// (`dart:ui`, which turns the photo upright by its EXIF orientation, as
/// the image screen shows it). Downloads honour Wi-Fi only through
/// `isMeteredConnection` and can be stopped ([cancelOcrDownload]).
class TesseractTextRecognitionService
    implements
        TextRecognitionService,
        CancellableOcrDownloads,
        TextRecognitionConfidence,
        TextRecognitionPixels {
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

  /// The running [downloadOcrLanguage] calls, by code.
  final Map<String, Set<_Download>> _downloads = {};

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
  Future<String> recognizeWith(PickedImage image, List<String> codes) async =>
      (await recognizeWithConfidence(image, codes)).text;

  @override
  Future<TextWithConfidence> recognizeWithConfidence(
    PickedImage image,
    List<String> codes,
  ) async {
    await _engine();
    final decoded = await _decoder.decode(image.bytes);
    return await recognizePixels(
      decoded.pixels,
      width: decoded.width,
      height: decoded.height,
      codes: codes,
    );
  }

  @override
  Future<TextWithConfidence> recognizePixels(
    Uint8List pixels, {
    required int width,
    required int height,
    required List<String> codes,
    int bytesPerPixel = 4,
    int? bytesPerLine,
  }) async {
    final ocr = await _engine();
    try {
      final result = await ocr.recognize(
        pixels,
        width,
        height,
        languages: codes,
        bytesPerPixel: bytesPerPixel,
        bytesPerLine: bytesPerLine,
        layout: true,
      );
      return TextWithConfidence(
        result.text,
        confidence: result.meanConfidence,
        layout: textLayoutOf(result.layout),
      );
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

  /// Fails with an [OfflineDownloadCancelledException] once
  /// [cancelOcrDownload] stopped it (also before its request was sent).
  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    final download = _Download();
    final running = (_downloads[code] ??= {})..add(download);
    try {
      final ocr = await _engine();
      if (wifiOnly && await _isMetered()) {
        throw const MeteredConnectionException();
      }
      if (download.cancelled) throw OfflineDownloadCancelledException(code);
      // The settings' model source (SHARED W3-B): GitHub or a mirror.
      final source = ModelSource.current;
      ocr.data
        ..mirror = source.mirror()
        ..fallbackToDefault = source.fallsBackToDefault;
      // Starts (and registers) the install before it awaits anything, so
      // a cancel from now on reaches it.
      await ocr.download(
        code,
        onProgress: onProgress == null
            ? null
            : (progress) => onProgress(progress.fraction),
      );
    } on TessdataDownloadCancelledException {
      throw OfflineDownloadCancelledException(code);
    } finally {
      running.remove(download);
      if (running.isEmpty && identical(_downloads[code], running)) {
        _downloads.remove(code);
      }
    }
    _changes.add(null);
  }

  @override
  Future<void> cancelOcrDownload(String code) async {
    final running = _downloads[code];
    if (running == null || running.isEmpty) return;
    for (final download in running) {
      download.cancelled = true;
    }
    try {
      await (await _engine()).cancelDownload(code);
    } on Object {
      // No engine: no request was sent (the downloads fail on their own).
    }
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

  /// The paragraphs of Tesseract's [layout] with their lines joined
  /// ([TextParagraph.joinLines]), without those that have no letter or
  /// digit or are a very unsure one or two characters (specks, edges and
  /// textures read as text); null without a layout.
  static TextLayout? textLayoutOf(OcrLayout? layout) {
    if (layout == null) return null;
    return TextLayout(
      width: layout.width,
      height: layout.height,
      paragraphs: [
        for (final paragraph in layout.paragraphs) ?_paragraphOf(paragraph),
      ],
    );
  }

  static TextParagraph? _paragraphOf(OcrParagraph paragraph) {
    final text = TextParagraph.joinLines([
      for (final line in paragraph.lines) line.text,
    ]);
    if (!_letterOrDigit.hasMatch(text)) return null;
    if (paragraph.confidence < _speckConfidence && text.runes.length <= 2) {
      return null;
    }
    final box = paragraph.box;
    Color? colour(int? rgb) => rgb == null ? null : Color(0xFF000000 | rgb);
    return TextParagraph(
      text: text,
      box: Rect.fromLTRB(
        box.left.toDouble(),
        box.top.toDouble(),
        box.right.toDouble(),
        box.bottom.toDouble(),
      ),
      lineCount: paragraph.lines.isEmpty ? 1 : paragraph.lines.length,
      alignment: switch (paragraph.alignment) {
        OcrAlignment.left => TextParagraphAlignment.left,
        OcrAlignment.center => TextParagraphAlignment.center,
        OcrAlignment.right => TextParagraphAlignment.right,
        OcrAlignment.unknown => TextParagraphAlignment.unknown,
      },
      isRightToLeft: !paragraph.isLeftToRight,
      background: colour(paragraph.background),
      foreground: colour(paragraph.foreground),
      confidence: paragraph.confidence,
    );
  }

  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Below this confidence a paragraph of one or two characters is taken
  /// for a speck.
  static const _speckConfidence = 30;

  static OcrLanguage _describe(TessdataLanguage language) => OcrLanguage(
    code: language.code,
    appCode: language.languages.first,
    downloadSize: language.size,
    url: language.url,
  );
}

/// A running [TesseractTextRecognitionService.downloadOcrLanguage] call.
final class _Download {
  /// [TesseractTextRecognitionService.cancelOcrDownload] was called for it.
  bool cancelled = false;
}
