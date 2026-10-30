import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/image_translate/models/models.dart';

import 'pdf_fakes.dart';

void main() {
  late FakePdfPages pages;
  late FakePdfRecognizer recognizer;

  setUp(() {
    pages = FakePdfPages();
    recognizer = FakePdfRecognizer();
  });

  PdfPageReader reader({int minConfidence = 40}) => PdfPageReader(
    pages: pages,
    recognizer: recognizer,
    minConfidence: minConfidence,
  );

  group('PdfPageReader.readPixels', () {
    test('300 dpi, within 8 megapixels', () {
      // A6 at 300 dpi: 1240 x 1748 pixels.
      expect(
        PdfPageReader.readPixels(const Size(298, 420)),
        closeTo(1241 * 1750, 5000),
      );
      // Letter at 300 dpi would be 8.4 megapixels.
      expect(
        PdfPageReader.readPixels(const Size(612, 792)),
        PdfLimits.maxPixels,
      );
      expect(PdfPageReader.readPixels(const Size(0.01, 0.01)), 1);
      expect(
        PdfPageReader.readPixels(const Size(double.infinity, 10)),
        PdfLimits.maxPixels,
      );
    });
  });

  group('PdfPageReader.read', () {
    test('renders, reads with the codes and maps pixels to points', () async {
      // Letter rendered 1224 x 1584 pixels: 2 pixels per point.
      pages.renderPage = (page, maxPixels) => whiteImage(
        1224,
        1584,
        fill: {
          const Rect.fromLTRB(100, 200, 300, 220): const Color(0xFF000000),
        },
      );
      recognizer.layoutFor = (width, height, codes) => layoutOf(width, height, [
        paragraph('Hello world', const Rect.fromLTRB(100, 200, 300, 220)),
      ]);
      final page = await reader().read(0, const Size(612, 792), ['eng']);
      expect(pages.renders.single, (page: 0, maxPixels: PdfLimits.maxPixels));
      final read0 = recognizer.reads.single;
      expect((read0.width, read0.height), (1224, 1584));
      expect(read0.codes, ['eng']);
      expect(read0.bytesPerPixel, 4);
      expect(page.page, 0);
      expect(page.size, const Size(612, 792));
      expect(page.codes, ['eng']);
      expect(page.readWith(['eng']), isTrue);
      expect(page.readWith(['deu']), isFalse);
      final read = page.paragraphs.single;
      expect(read.text, 'Hello world');
      // 2 pixels of margin around the box, in points.
      expect(read.rect, const Rect.fromLTRB(49, 99, 151, 111));
      expect(read.fontSize, 10);
      expect(read.background, const Color(0xFFFFFFFF));
      expect(read.foreground, const Color(0xFF000000));
      expect(read.align, PdfTextAlign.start);
      expect(page.segments.single.text, 'Hello world');
      expect(page.isEmpty, isFalse);
    });

    test('maps pages of other sizes and scales separately', () async {
      // A4 landscape read at 1 pixel per point across, 0.5 down.
      pages.renderPage = (page, maxPixels) => whiteImage(842, 298);
      recognizer.layoutFor = (width, height, codes) => layoutOf(width, height, [
        paragraph(
          'Two\nlines',
          const Rect.fromLTRB(40, 100, 140, 140),
          lineCount: 2,
        ),
      ]);
      final page = await reader().read(3, const Size(842, 595), ['eng']);
      final read = page.paragraphs.single;
      expect(read.rect.left, closeTo(40 - 2, 0.001));
      expect(read.rect.right, closeTo(140 + 2, 0.001));
      expect(read.rect.top, closeTo((100 - 2) * 595 / 298, 0.001));
      expect(read.rect.bottom, closeTo((140 + 2) * 595 / 298, 0.001));
      // Line pitch 20 pixels down.
      expect(read.fontSize, closeTo(20 * 595 / 298, 0.001));
    });

    test('maps a layout read at another size than the image', () async {
      pages.renderPage = (page, maxPixels) => whiteImage(400, 400);
      recognizer.layoutFor = (width, height, codes) => layoutOf(200, 200, [
        paragraph('Half', const Rect.fromLTRB(10, 10, 60, 30)),
      ]);
      final page = await reader().read(0, const Size(400, 400), ['eng']);
      // Doubled to the image, which is 1 pixel per point; the margin is 8%
      // of the 40 pixel line pitch.
      final rect = page.paragraphs.single.rect;
      expect(rect.left, closeTo(16.8, 1e-9));
      expect(rect.top, closeTo(16.8, 1e-9));
      expect(rect.right, closeTo(123.2, 1e-9));
      expect(rect.bottom, closeTo(63.2, 1e-9));
    });

    test('keeps boxes on the page', () async {
      pages.renderPage = (page, maxPixels) => whiteImage(100, 100);
      recognizer.layoutFor = (width, height, codes) => layoutOf(width, height, [
        paragraph('Edge', const Rect.fromLTRB(0, 0, 100, 10)),
      ]);
      final page = await reader().read(0, const Size(100, 100), ['eng']);
      expect(page.paragraphs.single.rect, const Rect.fromLTRB(0, 0, 100, 12));
    });

    test('leaves out unsure paragraphs, keeps unknown confidence', () async {
      recognizer.layoutFor = (width, height, codes) => layoutOf(width, height, [
        paragraph('Speckles', const Rect.fromLTRB(1, 1, 50, 9), confidence: 30),
        paragraph('Sure', const Rect.fromLTRB(1, 20, 50, 29)),
        paragraph(
          'Unknown',
          const Rect.fromLTRB(1, 40, 50, 49),
          confidence: null,
        ),
      ]);
      final page = await reader().read(0, const Size(100, 200), ['eng']);
      expect([for (final p in page.paragraphs) p.text], ['Sure', 'Unknown']);
      final lenient = await reader(minConfidence: 0)
          .read(0, const Size(100, 200), ['eng']);
      expect(lenient.paragraphs, hasLength(3));
    });

    test('a page without text has no paragraphs', () async {
      final page = await reader().read(1, const Size(612, 792), ['eng']);
      expect(page.isEmpty, isTrue);
      expect(page.segments, isEmpty);
    });

    test('passes the errors on', () async {
      pages.renderErrors[0] = const PdfRenderException(page: 0);
      await expectLater(
        reader().read(0, const Size(10, 10), ['eng']),
        throwsA(isA<PdfRenderException>()),
      );
      recognizer.errorsByWidth[FakePdfPages.widthOf(1)] =
          const OcrDataMissingException(germanOcr);
      await expectLater(
        reader().read(1, const Size(10, 10), ['deu']),
        throwsA(const OcrDataMissingException(germanOcr)),
      );
    });
  });

  group('PdfPageReader.textLayerPixels', () {
    test('144 dpi, within 2 megapixels', () {
      // A5 at 144 dpi: 840 x 1190 pixels.
      expect(
        PdfPageReader.textLayerPixels(const Size(420, 595)),
        closeTo(840 * 1190, 3000),
      );
      expect(PdfPageReader.textLayerPixels(const Size(612, 792)), 1224 * 1584);
      // A3 would be 2.1 megapixels.
      expect(
        PdfPageReader.textLayerPixels(const Size(842, 1191)),
        PdfLimits.maxTextLayerPixels,
      );
    });
  });

  group('PdfPageReader text layer', () {
    const letter = Size(612, 792);
    const text = [
      PdfTextLine(
        text: 'The text layer of the file',
        rect: Rect.fromLTRB(100, 100, 300, 112),
      ),
      PdfTextLine(
        text: 'goes on here.',
        rect: Rect.fromLTRB(100, 114, 200, 126),
      ),
    ];

    test('is read instead of recognising the page', () async {
      // Letter rendered 612 x 792: 1 pixel per point.
      pages
        ..textLayers[0] = text
        ..renderPage = (page, maxPixels) => whiteImage(
          612,
          792,
          fill: {
            const Rect.fromLTRB(100, 100, 300, 126): const Color(0xFF202020),
          },
        );
      final page = await reader().read(0, letter, ['eng']);
      expect(recognizer.reads, isEmpty);
      // Rendered small, only for the colours.
      expect(pages.renders.single, (page: 0, maxPixels: 1224 * 1584));
      expect(page.fromTextLayer, isTrue);
      expect(page.codes, ['eng']);
      // The same text whatever the recognition data.
      expect(page.readWith(['deu']), isTrue);
      final paragraph = page.paragraphs.single;
      expect(paragraph.text, 'The text layer of the file goes on here.');
      expect(paragraph.rect, const Rect.fromLTRB(98, 98, 302, 128));
      expect(paragraph.fontSize, 13);
      expect(paragraph.align, PdfTextAlign.start);
      expect(paragraph.foreground, const Color(0xFF202020));
      expect(paragraph.background, const Color(0xFFFFFFFF));
    });

    test('a page with too little text is recognised', () async {
      pages.textLayers[0] = const [
        PdfTextLine(text: '12', rect: Rect.fromLTRB(300, 760, 312, 772)),
      ];
      recognizer.layoutFor = (width, height, codes) => layoutOf(width, height, [
        paragraph('Scanned text', const Rect.fromLTRB(10, 10, 90, 30)),
      ]);
      final read = reader();
      expect(await read.hasTextLayer(0), isFalse);
      expect(await read.readTextLayer(0, letter), isNull);
      final page = await read.read(0, letter, ['eng']);
      expect(page.fromTextLayer, isFalse);
      expect(page.paragraphs.single.text, 'Scanned text');
      expect(recognizer.reads, hasLength(1));
      // The text layer was asked for once.
      expect(pages.textReads, [0]);
    });

    test('before Android 15 every page is recognised', () async {
      final read = reader();
      expect(await read.hasTextLayer(0), isFalse);
      await read.read(0, letter, ['eng']);
      expect(recognizer.reads, hasLength(1));
    });

    test('forget asks for the text layers again', () async {
      pages.textLayers[0] = text;
      final read = reader();
      expect(await read.hasTextLayer(0), isTrue);
      expect(await read.hasTextLayer(0), isTrue);
      expect(pages.textReads, [0]);
      read.forget();
      expect(await read.hasTextLayer(0), isTrue);
      expect(pages.textReads, [0, 0]);
    });

    test('without a recognizer only text layers are read', () async {
      pages.textLayers[0] = text;
      final read = PdfPageReader(pages: pages, recognizer: null);
      expect(read.canRecognize, isFalse);
      expect((await read.read(0, letter, const [])).fromTextLayer, isTrue);
      await expectLater(
        read.read(1, letter, ['eng']),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionFailed,
          ),
        ),
      );
    });
  });

  group('PdfPageReader.alignOf', () {
    test('turns alignment as seen into start and end', () {
      PdfTextAlign align(
        TextParagraphAlignment alignment, {
        bool rtl = false,
      }) => PdfPageReader.alignOf(
        paragraph('x', Rect.zero, alignment: alignment, rtl: rtl),
      );
      expect(align(TextParagraphAlignment.left), PdfTextAlign.start);
      expect(align(TextParagraphAlignment.right), PdfTextAlign.end);
      expect(align(TextParagraphAlignment.center), PdfTextAlign.center);
      expect(align(TextParagraphAlignment.unknown), PdfTextAlign.start);
      expect(
        align(TextParagraphAlignment.right, rtl: true),
        PdfTextAlign.start,
      );
      expect(align(TextParagraphAlignment.left, rtl: true), PdfTextAlign.end);
    });
  });
}
