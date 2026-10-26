import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

/// The bytes of a (tiny) PDF: the header is all the app looks at.
final pdfBytes = Uint8List.fromList(utf8.encode('%PDF-1.7\n%âãÏÓ\n1 0 obj\n'));

/// A white RGBA image, [width] x [height], with [fill]'s colours painted
/// into its pixel rectangles.
PdfPageImage whiteImage(
  int width,
  int height, {
  Map<Rect, Color> fill = const {},
}) {
  final pixels = Uint8List(width * height * 4)
    ..fillRange(0, width * height * 4, 255);
  for (final MapEntry(key: rect, value: colour) in fill.entries) {
    final argb = colour.toARGB32();
    for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
      for (var x = rect.left.toInt(); x < rect.right.toInt(); x++) {
        final offset = (y * width + x) * 4;
        pixels[offset] = (argb >> 16) & 0xFF;
        pixels[offset + 1] = (argb >> 8) & 0xFF;
        pixels[offset + 2] = argb & 0xFF;
        pixels[offset + 3] = 255;
      }
    }
  }
  return PdfPageImage(pixels: pixels, width: width, height: height);
}

/// In-memory [PdfPages]: page n renders as [renderPage] says (default: a
/// white image `100 + 10 n` pixels wide and 200 high, so the fake
/// recognizer can tell pages apart by their width).
class FakePdfPages implements PdfPages {
  new({this.pageSizes = const [Size(612, 792)], this.scratch});

  List<Size> pageSizes;
  FakePdfScratch? scratch;
  bool supported = true;
  Exception? openError;
  final Map<int, Exception> renderErrors = {};
  Exception? writeError;
  Uint8List written = Uint8List.fromList(utf8.encode('%PDF-1.4 translated'));
  PdfPageImage Function(int page, int maxPixels)? renderPage;

  /// While set, renders wait for it.
  Completer<void>? renderGate;

  final List<String> opened = [];
  final List<({int page, int maxPixels})> renders = [];
  final List<({String path, List<PdfOutputPage> pages})> writes = [];
  int closes = 0;

  static int widthOf(int page) => 100 + 10 * page;

  @override
  bool get isSupported => supported;

  @override
  Future<PdfInfo> open(String path) async {
    opened.add(path);
    if (openError case final error?) throw error;
    return PdfInfo(pageSizes: pageSizes);
  }

  @override
  Future<PdfPageImage> render(int page, {required int maxPixels}) async {
    renders.add((page: page, maxPixels: maxPixels));
    if (renderGate case final gate?) await gate.future;
    if (renderErrors[page] case final error?) throw error;
    return renderPage?.call(page, maxPixels) ?? whiteImage(widthOf(page), 200);
  }

  @override
  Future<void> write(String outputPath, List<PdfOutputPage> pages) async {
    writes.add((path: outputPath, pages: pages));
    if (writeError case final error?) throw error;
    scratch?.files[outputPath] = written;
  }

  @override
  Future<void> close() async => closes++;
}

/// In-memory [PdfScratch].
class FakePdfScratch implements PdfScratch {
  final Map<String, Uint8List> files = {};
  final List<String> deleted = [];
  Exception? writeError;
  var _next = 0;

  @override
  Future<String> write(Uint8List bytes) async {
    if (writeError case final error?) throw error;
    final path = await newPath();
    files[path] = bytes;
    return path;
  }

  @override
  Future<String> newPath() async => '/cache/pdf_pages/${_next++}.pdf';

  @override
  Future<Uint8List> take(String path) async {
    final bytes = files.remove(path);
    if (bytes == null) throw StateError('no file $path');
    return bytes;
  }

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
    files.remove(path);
  }
}

const englishOcr = OcrLanguage(code: 'eng', appCode: 'en', downloadSize: 4000);
const germanOcr = OcrLanguage(code: 'deu', appCode: 'de', downloadSize: 1500);

/// A recognizer with language data and raw-pixel reading: [layoutFor]
/// gives the layout of an image (default: none).
class FakePdfRecognizer
    implements
        TextRecognitionService,
        TextRecognitionLanguageData,
        TextRecognitionPixels {
  new({this.layoutFor});

  TextLayout? Function(int width, int height, List<String> codes)? layoutFor;
  @override
  bool isSupported = true;
  Map<String, int> installed = {'eng': 4000};
  final Map<int, Exception> errorsByWidth = {};
  final List<({int width, int height, List<String> codes, int bytesPerPixel})>
  reads = [];
  final _changes = StreamController<void>.broadcast();

  @override
  Future<TextWithConfidence> recognizePixels(
    Uint8List pixels, {
    required int width,
    required int height,
    required List<String> codes,
    int bytesPerPixel = 4,
    int? bytesPerLine,
  }) async {
    reads.add((
      width: width,
      height: height,
      codes: codes,
      bytesPerPixel: bytesPerPixel,
    ));
    if (errorsByWidth[width] case final error?) throw error;
    final layout = layoutFor?.call(width, height, codes);
    return TextWithConfidence(layout?.text ?? '', layout: layout);
  }

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      throw UnimplementedError();

  @override
  Future<List<OcrLanguage>> ocrLanguages() async => [germanOcr, englishOcr];

  @override
  Future<OcrLanguage?> ocrLanguageFor(String code) async => switch (code) {
    'en' => englishOcr,
    'de' => germanOcr,
    _ => null,
  };

  @override
  Future<Map<String, int>> installedOcrLanguages() async => installed;

  @override
  Future<String> recognizeWith(PickedImage image, List<String> codes) =>
      throw UnimplementedError();

  @override
  Future<void> downloadOcrLanguage(
    String code, {
    required bool wifiOnly,
    void Function(double fraction)? onProgress,
  }) async {
    installed = {...installed, code: 1};
    _changes.add(null);
  }

  @override
  Future<void> deleteOcrLanguage(String code) async {}

  @override
  Future<OcrImportReport> importOcrFiles(List<String> paths) async =>
      const OcrImportReport();

  @override
  Stream<void> get ocrLanguagesChanged => _changes.stream;
}

/// A layout of [paragraphs] in an image of [width] x [height] pixels.
TextLayout layoutOf(int width, int height, List<TextParagraph> paragraphs) =>
    TextLayout(width: width, height: height, paragraphs: paragraphs);

/// A paragraph [text] at [box] (pixels).
TextParagraph paragraph(
  String text,
  Rect box, {
  int lineCount = 1,
  TextParagraphAlignment alignment = TextParagraphAlignment.left,
  bool rtl = false,
  int? confidence = 90,
}) => TextParagraph(
  text: text,
  box: box,
  lineCount: lineCount,
  alignment: alignment,
  isRightToLeft: rtl,
  confidence: confidence,
);
