import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/pdf/pdf.dart';
import 'package:mozhi/image_translate/models/models.dart';

PdfTextLine _line(String text, double left, double top, double right) =>
    PdfTextLine(text: text, rect: Rect.fromLTRB(left, top, right, top + 12));

void main() {
  group('PdfTextLayer.isUsable', () {
    test('wants enough letters and digits', () {
      expect(PdfTextLayer.isUsable(null), isFalse);
      expect(PdfTextLayer.isUsable(const []), isFalse);
      // A page number only (a scan's text layer).
      expect(PdfTextLayer.isUsable([_line('12', 300, 760, 312)]), isFalse);
      expect(
        PdfTextLayer.isUsable([
          _line('The quick brown fox jumps', 72, 72, 300),
        ]),
        isTrue,
      );
      // Lines without a box do not count.
      expect(
        PdfTextLayer.isUsable([
          const PdfTextLine(
            text: 'The quick brown fox jumps',
            rect: Rect.fromLTRB(10, 10, 10, 10),
          ),
        ]),
        isFalse,
      );
    });

    test('refuses text the file cannot name (no character map)', () {
      expect(
        PdfTextLayer.isUsable([
          _line('Hello world, this is fine \uFFFD', 72, 72, 300),
        ]),
        isTrue,
      );
      expect(
        PdfTextLayer.isUsable([
          _line(
            'Hello world and more text here \uE001\uE002\uE003\uE004',
            72,
            72,
            300,
          ),
        ]),
        isFalse,
      );
    });
  });

  group('PdfTextLayer.groupLines', () {
    test('joins the lines of a paragraph, splits at wide gaps', () {
      final lines = [
        _line('First paragraph, line one', 72, 100, 500),
        _line('and line two.', 72, 114, 300),
        // A wider gap: a new paragraph.
        _line('Second paragraph', 72, 140, 400),
        _line('goes on here', 72, 154, 380),
        // Much wider than the first gap of this paragraph.
        _line('Third', 72, 175, 200),
      ];
      expect(PdfTextLayer.groupLines(lines), [
        lines.sublist(0, 2),
        lines.sublist(2, 4),
        [lines[4]],
      ]);
    });

    test('keeps columns, headings and lines going up apart', () {
      final lines = [
        _line('Left column', 72, 100, 280),
        // Beside it: no horizontal overlap.
        _line('Right column', 320, 114, 540),
        // Below it.
        _line('goes on below it', 320, 128, 540),
        const PdfTextLine(text: 'Big', rect: Rect.fromLTRB(320, 142, 540, 172)),
        // Above the line before it (a new column starts at the top).
        _line('Back to the top', 320, 40, 540),
      ];
      expect(PdfTextLayer.groupLines(lines), hasLength(4));
    });
  });

  group('PdfTextLayer.alignmentOf', () {
    test('reads the edges that line up', () {
      final left = [
        _line('aaaa aaaa aaaa', 72, 100, 400),
        _line('aaaa aaaa', 72, 114, 300),
      ];
      expect(PdfTextLayer.alignmentOf(left), TextParagraphAlignment.left);
      final justified = [
        _line('aaaa aaaa aaaa', 72, 100, 400),
        _line('aaaa aaaa aaaa', 72, 114, 400),
        _line('aaaa', 72, 128, 150),
      ];
      expect(PdfTextLayer.alignmentOf(justified), TextParagraphAlignment.left);
      final right = [
        _line('aaaa aaaa aaaa', 100, 100, 400),
        _line('aaaa', 300, 114, 400),
      ];
      expect(PdfTextLayer.alignmentOf(right), TextParagraphAlignment.right);
      final centred = [
        _line('aaaa aaaa aaaa', 100, 100, 400),
        _line('aaaa', 200, 114, 300),
      ];
      expect(PdfTextLayer.alignmentOf(centred), TextParagraphAlignment.center);
      final ragged = [
        _line('aaaa aaaa aaaa', 100, 100, 400),
        _line('aaaa', 120, 114, 200),
      ];
      expect(PdfTextLayer.alignmentOf(ragged), TextParagraphAlignment.left);
    });

    test('a single line by its direction', () {
      final line = [_line('aaaa', 72, 100, 150)];
      expect(PdfTextLayer.alignmentOf(line), TextParagraphAlignment.left);
      expect(
        PdfTextLayer.alignmentOf(line, rightToLeft: true),
        TextParagraphAlignment.right,
      );
    });

    test('right to left prefers the right edge', () {
      final justified = [
        _line('aaaa aaaa aaaa', 72, 100, 400),
        _line('aaaa aaaa aaaa', 72, 114, 400),
      ];
      expect(
        PdfTextLayer.alignmentOf(justified, rightToLeft: true),
        TextParagraphAlignment.right,
      );
      final left = [
        _line('aaaa aaaa aaaa', 72, 100, 400),
        _line('aaaa', 72, 114, 150),
      ];
      expect(
        PdfTextLayer.alignmentOf(left, rightToLeft: true),
        TextParagraphAlignment.left,
      );
      final centred = [
        _line('aaaa aaaa aaaa', 100, 100, 400),
        _line('aaaa', 200, 114, 300),
      ];
      expect(
        PdfTextLayer.alignmentOf(centred, rightToLeft: true),
        TextParagraphAlignment.center,
      );
      final ragged = [
        _line('aaaa aaaa aaaa', 100, 100, 400),
        _line('aaaa', 120, 114, 200),
      ];
      expect(
        PdfTextLayer.alignmentOf(ragged, rightToLeft: true),
        TextParagraphAlignment.right,
      );
    });
  });

  group('PdfTextLayer.layoutOf', () {
    test('is the layout text recognition gives, in pixels', () {
      final layout = PdfTextLayer.layoutOf(
        [
          _line('Hello', 100, 100, 200),
          _line('world', 100, 114, 190),
          // Nothing to translate, or off the page.
          _line('—', 100, 300, 120),
          _line('Gone', 700, 100, 800),
          _line('  مرحبا بالعالم  ', 300, 400, 500),
        ],
        page: const Size(600, 800),
        width: 300,
        height: 400,
      );
      expect(layout.width, 300);
      expect(layout.height, 400);
      expect(layout.paragraphs, hasLength(2));
      final first = layout.paragraphs.first;
      expect(first.text, 'Hello world');
      expect(first.box, const Rect.fromLTRB(50, 50, 100, 63));
      expect(first.lineCount, 2);
      expect(first.alignment, TextParagraphAlignment.left);
      expect(first.isRightToLeft, isFalse);
      expect(first.confidence, PdfTextLayer.confidence);
      final arabic = layout.paragraphs.last;
      expect(arabic.text, 'مرحبا بالعالم');
      expect(arabic.isRightToLeft, isTrue);
      expect(arabic.alignment, TextParagraphAlignment.right);
    });
  });
}
