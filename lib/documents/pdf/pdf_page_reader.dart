import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:mozhi/documents/pdf/pdf_colours.dart';
import 'package:mozhi/documents/pdf/pdf_document.dart';
import 'package:mozhi/documents/pdf/pdf_pages.dart';
import 'package:mozhi/documents/pdf/pdf_text_layer.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';

/// Reads the text of PDF pages on the device, from the page's text layer
/// when it has one, else with text recognition, into the same layout
/// ([TextLayout]) either way:
///
/// * [readTextLayer]: the file's own text ([PdfPages.readText], Android 15
///   and later), when the page has enough of it ([PdfTextLayer.isUsable]),
///   its lines grouped into paragraphs ([PdfTextLayer.layoutOf]). Exactly
///   the file's text, at once, with no recognition data. The page is
///   rendered small ([PdfLimits.textLayerDpi]) only to sample its colours.
/// * [recognize]: renders the page ([PdfPages.render], at most
///   [PdfLimits.readDpi] and [PdfLimits.maxPixels]) and recognises it with
///   its layout (Tesseract, [TextRecognitionPixels]).
///
/// Every paragraph becomes a [PdfParagraph]: its box mapped from pixels to
/// points (a little larger, so the anti-aliased edges of the original are
/// covered too), its colours sampled from the page
/// ([sampleBlockColours]), its alignment and its line pitch as the font
/// size. The rendered pixels are dropped once the page is read.
///
/// Paragraphs recognised with a confidence under [minConfidence] (pictures
/// and textures read as text) are left out: they stay as they are in the
/// translated PDF.
class PdfPageReader {
  new({
    required this._pages,
    required this._recognizer,
    this.minConfidence = 40,
  });

  final PdfPages _pages;

  /// Null: pages are read only from their text layers.
  final TextRecognitionPixels? _recognizer;

  /// See the class documentation.
  final int minConfidence;

  /// Text layers read so far, by page (null: not read here).
  final Map<int, List<PdfTextLine>?> _layers = {};

  /// How many pixels a page of [size] points is rendered with for reading.
  static int readPixels(Size size) =>
      _pixels(size, PdfLimits.readDpi, PdfLimits.maxPixels);

  /// How many pixels a page of [size] points read from its text layer is
  /// rendered with (for its colours).
  static int textLayerPixels(Size size) =>
      _pixels(size, PdfLimits.textLayerDpi, PdfLimits.maxTextLayerPixels);

  static int _pixels(Size size, int dpi, int most) {
    final scale = dpi / 72;
    final pixels = size.width * scale * (size.height * scale);
    if (!pixels.isFinite || pixels > most) return most;
    return math.max(1, pixels.floor());
  }

  /// Whether pages without a text layer can be read (text recognition).
  bool get canRecognize => _recognizer != null;

  /// Forgets the text layers read (another PDF is open).
  void forget() => _layers.clear();

  /// Whether page [page] has a text layer that carries its text
  /// ([PdfTextLayer.isUsable]); asked once per page.
  Future<bool> hasTextLayer(int page) async =>
      PdfTextLayer.isUsable(await _textLayer(page));

  Future<List<PdfTextLine>?> _textLayer(int page) async {
    if (_layers.containsKey(page)) return _layers[page];
    final lines = await _pages.readText(page);
    return _layers[page] = lines;
  }

  /// Reads page [page] (of [size] points): from its text layer when it has
  /// one ([readTextLayer]), else with the recognition languages [codes]
  /// ([recognize]). Throws [PdfRenderException], [OcrDataMissingException]
  /// or [ImageTranslateException] (`recognitionFailed`).
  Future<PdfPageText> read(int page, Size size, List<String> codes) async =>
      await readTextLayer(page, size, codes: codes) ??
      await recognize(page, size, codes);

  /// Page [page] (of [size] points) from its text layer, marked as read
  /// with [codes] ([PdfPageText.fromTextLayer]); null when it has none
  /// that carries its text. Throws [PdfRenderException].
  Future<PdfPageText?> readTextLayer(
    int page,
    Size size, {
    List<String> codes = const [],
  }) async {
    final lines = await _textLayer(page);
    if (lines == null || !PdfTextLayer.isUsable(lines)) return null;
    final image = await _pages.render(page, maxPixels: textLayerPixels(size));
    final layout = PdfTextLayer.layoutOf(
      lines,
      page: size,
      width: image.width,
      height: image.height,
    );
    return PdfPageText(
      page: page,
      size: size,
      codes: List.unmodifiable(codes),
      fromTextLayer: true,
      paragraphs: [
        for (final paragraph in layout.paragraphs)
          paragraphOf(paragraph, image, layout, size),
      ],
    );
  }

  /// Reads page [page] (of [size] points) with text recognition in
  /// [codes]. Throws [PdfRenderException], [OcrDataMissingException] or
  /// [ImageTranslateException] (`recognitionFailed`, also without a
  /// recognizer).
  Future<PdfPageText> recognize(int page, Size size, List<String> codes) async {
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw const ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
      );
    }
    final image = await _pages.render(page, maxPixels: readPixels(size));
    final recognized = await recognizer.recognizePixels(
      image.pixels,
      width: image.width,
      height: image.height,
      codes: codes,
      bytesPerPixel: image.bytesPerPixel,
      bytesPerLine: image.bytesPerLine,
    );
    final layout = recognized.layout;
    return PdfPageText(
      page: page,
      size: size,
      codes: List.unmodifiable(codes),
      paragraphs: [
        if (layout != null)
          for (final paragraph in layout.paragraphs)
            if ((paragraph.confidence ?? 100) >= minConfidence)
              paragraphOf(paragraph, image, layout, size),
      ],
    );
  }

  /// [paragraph] of [layout] (read from [image]) on a page of [size]
  /// points.
  static PdfParagraph paragraphOf(
    TextParagraph paragraph,
    PdfPageImage image,
    TextLayout layout,
    Size size,
  ) {
    // The layout is in pixels of the image it read (the rendered page).
    final toImageX = layout.width > 0 ? image.width / layout.width : 1.0;
    final toImageY = layout.height > 0 ? image.height / layout.height : 1.0;
    final box = Rect.fromLTRB(
      paragraph.box.left * toImageX,
      paragraph.box.top * toImageY,
      paragraph.box.right * toImageX,
      paragraph.box.bottom * toImageY,
    );
    final pitch = paragraph.linePitch * toImageY;
    final pad = math.max(2, pitch * 0.08);
    final covered = box.inflate(pad.toDouble());
    final colours = sampleBlockColours(
      image,
      covered,
      ring: math.max(3, (pitch * 0.25).round()),
    );
    final toPointsX = size.width / image.width;
    final toPointsY = size.height / image.height;
    final rect = Rect.fromLTRB(
      (covered.left * toPointsX).clamp(0, size.width),
      (covered.top * toPointsY).clamp(0, size.height),
      (covered.right * toPointsX).clamp(0, size.width),
      (covered.bottom * toPointsY).clamp(0, size.height),
    );
    return PdfParagraph(
      text: paragraph.text,
      rect: rect,
      background: colours.background,
      foreground: colours.foreground,
      align: alignOf(paragraph),
      fontSize: pitch * toPointsY,
    );
  }

  /// [paragraph]'s alignment as seen, relative to its own direction: a
  /// left-aligned paragraph of a left-to-right script starts its lines at
  /// the start, so does its right-to-left translation (on the right).
  static PdfTextAlign alignOf(TextParagraph paragraph) =>
      switch (paragraph.alignment) {
        TextParagraphAlignment.center => PdfTextAlign.center,
        TextParagraphAlignment.left =>
          paragraph.isRightToLeft ? PdfTextAlign.end : PdfTextAlign.start,
        TextParagraphAlignment.right =>
          paragraph.isRightToLeft ? PdfTextAlign.start : PdfTextAlign.end,
        TextParagraphAlignment.unknown => PdfTextAlign.start,
      };
}
