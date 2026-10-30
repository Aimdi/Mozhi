import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/pdf/pdf.dart';

import 'pdf_fakes.dart';

void main() {
  group('sampleBlockColours', () {
    test('dark text on white: white around, the strokes inside', () {
      // A 20 x 10 box with a black bar (strokes) in it.
      final image = whiteImage(
        100,
        50,
        fill: {const Rect.fromLTRB(22, 14, 38, 16): const Color(0xFF000000)},
      );
      final colours = sampleBlockColours(
        image,
        const Rect.fromLTRB(20, 10, 40, 20),
      );
      expect(colours.background, const Color(0xFFFFFFFF));
      expect(colours.foreground, const Color(0xFF000000));
    });

    test('a coloured page and coloured text', () {
      final image = whiteImage(
        60,
        60,
        fill: {
          const Rect.fromLTRB(0, 0, 60, 60): const Color(0xFF203080),
          const Rect.fromLTRB(20, 25, 40, 28): const Color(0xFFFFE000),
        },
      );
      final colours = sampleBlockColours(
        image,
        const Rect.fromLTRB(18, 22, 42, 32),
      );
      expect(colours.background, const Color(0xFF203080));
      // The lightest pixels on the dark page are the text.
      expect(colours.foreground, const Color(0xFFFFE000));
    });

    test('the median ignores a rule crossing the ring', () {
      final image = whiteImage(
        100,
        40,
        fill: {
          // A thin red rule under the box, and grey text inside.
          const Rect.fromLTRB(0, 23, 100, 24): const Color(0xFFFF0000),
          const Rect.fromLTRB(12, 12, 50, 15): const Color(0xFF555555),
        },
      );
      final colours = sampleBlockColours(
        image,
        const Rect.fromLTRB(10, 10, 60, 20),
        ring: 4,
      );
      expect(colours.background, const Color(0xFFFFFFFF));
      expect(colours.foreground, const Color(0xFF555555));
    });

    test('without contrast: black on light, white on dark', () {
      final light = whiteImage(30, 30);
      expect(
        sampleBlockColours(light, const Rect.fromLTRB(5, 5, 25, 25)).foreground,
        const Color(0xFF000000),
      );
      final dark = whiteImage(
        30,
        30,
        fill: {const Rect.fromLTRB(0, 0, 30, 30): const Color(0xFF101010)},
      );
      final colours = sampleBlockColours(
        dark,
        const Rect.fromLTRB(5, 5, 25, 25),
      );
      expect(colours.background, const Color(0xFF101010));
      expect(colours.foreground, const Color(0xFFFFFFFF));
    });

    test('a box covering the page samples itself for the background', () {
      final image = whiteImage(
        10,
        10,
        fill: {
          const Rect.fromLTRB(0, 0, 10, 10): const Color(0xFFEEEEEE),
          const Rect.fromLTRB(2, 4, 8, 6): const Color(0xFF000000),
        },
      );
      final colours = sampleBlockColours(
        image,
        const Rect.fromLTRB(-5, -5, 20, 20),
      );
      expect(colours.background, const Color(0xFFEEEEEE));
      expect(colours.foreground, const Color(0xFF000000));
    });

    test('a box outside the page gives readable defaults', () {
      final colours = sampleBlockColours(
        whiteImage(10, 10),
        const Rect.fromLTRB(50, 50, 60, 60),
      );
      expect(colours.background, const Color(0xFFFFFFFF));
      expect(colours.foreground, const Color(0xFF000000));
    });

    test('reads grey pages', () {
      final pixels = Uint8List(20 * 20)..fillRange(0, 400, 230);
      for (var x = 6; x < 14; x++) {
        pixels[10 * 20 + x] = 20;
      }
      final image = PdfPageImage(
        pixels: pixels,
        width: 20,
        height: 20,
        bytesPerPixel: 1,
      );
      final colours = sampleBlockColours(
        image,
        const Rect.fromLTRB(5, 8, 15, 12),
      );
      expect(colours.background, const Color(0xFFE6E6E6));
      expect(colours.foreground, const Color(0xFF141414));
    });

    test('a large box is sampled, not read pixel by pixel', () {
      final image = whiteImage(
        1000,
        1000,
        fill: {
          const Rect.fromLTRB(100, 400, 900, 600): const Color(0xFF000000),
        },
      );
      final colours = sampleBlockColours(
        image,
        const Rect.fromLTRB(50, 300, 950, 700),
        maxSamples: 100,
      );
      expect(colours.background, const Color(0xFFFFFFFF));
      expect(colours.foreground, const Color(0xFF000000));
    });
  });
}
