import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:mozhi/documents/pdf/pdf_colours.dart';
import 'package:mozhi/documents/pdf/pdf_document.dart';
import 'package:mozhi/documents/pdf/pdf_pages.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';

/// Reads the text of PDF pages on the device: renders a page
/// ([PdfPages.render], at most [PdfLimits.readDpi] and
/// [PdfLimits.maxPixels]), recognises it with its layout (Tesseract,
/// [TextRecognitionPixels]) and turns every paragraph into a
/// [PdfParagraph]: its box mapped from pixels to points (a little larger,
/// so the anti-aliased edges of the original are covered too), its colours
/// sampled from the page ([sampleBlockColours]), its alignment and its
/// line pitch as the font size. The rendered pixels are dropped once the
/// page is read.
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
  final TextRecognitionPixels _recognizer;

  /// See the class documentation.
  final int minConfidence;

  /// How many pixels a page of [size] points is rendered with for reading.
  static int readPixels(Size size) {
    const scale = PdfLimits.readDpi / 72;
    final pixels = size.width * scale * (size.height * scale);
    if (!pixels.isFinite || pixels > PdfLimits.maxPixels) {
      return PdfLimits.maxPixels;
    }
    return math.max(1, pixels.floor());
  }

  /// Reads page [page] (of [size] points) with the recognition languages
  /// [codes]. Throws [PdfRenderException], [OcrDataMissingException] or
  /// [ImageTranslateException] (`recognitionFailed`).
  Future<PdfPageText> read(int page, Size size, List<String> codes) async {
    final image = await _pages.render(page, maxPixels: readPixels(size));
    final recognized = await _recognizer.recognizePixels(
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
