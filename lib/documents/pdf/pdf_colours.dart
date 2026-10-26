import 'dart:math' as math;
import 'dart:ui' show Color, Rect;

import 'package:mozhi/documents/pdf/pdf_pages.dart';

/// The colours of a text block on a rendered page.
typedef BlockColours = ({Color background, Color foreground});

/// Samples a rendered page's colours around and inside a text box (pixels
/// of [image], RGBA or grey):
///
/// * the background is the per-channel median of a ring of pixels just
///   outside the box ([ring] pixels wide), which other text, rules or
///   pictures crossing it rarely change;
/// * the text's colour is the average of the pixels inside the box that
///   differ most from the background in brightness (the darkest ones on a
///   light page, the lightest on a dark one): the strokes, not their
///   anti-aliased edges. When nothing in the box stands out (a box of
///   noise), black or white, whichever reads on the background.
///
/// At most about [maxSamples] pixels are looked at in each area (evenly
/// spaced), so a big box costs no more than a small one.
BlockColours sampleBlockColours(
  PdfPageImage image,
  Rect box, {
  int ring = 3,
  int maxSamples = 4096,
}) {
  final inner = _clip(box, image);
  final outer = _clip(box.inflate(ring.toDouble()), image);
  final background =
      _median(_ringSamples(image, outer, inner, maxSamples)) ??
      _median(_samples(image, inner, maxSamples)) ??
      const Color(0xFFFFFFFF);
  final foreground = _strokes(image, inner, background, maxSamples);
  return (background: background, foreground: foreground);
}

/// Integer pixel bounds of [rect] within [image]: (left, top, right,
/// bottom), right and bottom exclusive; empty when outside.
(int, int, int, int) _clip(Rect rect, PdfPageImage image) {
  final left = rect.left.floor().clamp(0, image.width);
  final top = rect.top.floor().clamp(0, image.height);
  final right = rect.right.ceil().clamp(left, image.width);
  final bottom = rect.bottom.ceil().clamp(top, image.height);
  return (left, top, right, bottom);
}

/// The step between sampled pixels so that an area of [count] pixels
/// gives at most about [maxSamples].
int _step(int count, int maxSamples) =>
    count <= maxSamples ? 1 : math.sqrt(count / maxSamples).ceil();

Color _pixel(PdfPageImage image, int x, int y) {
  final pixels = image.pixels;
  if (image.bytesPerPixel == 1) {
    final grey = pixels[y * image.bytesPerLine + x];
    return Color.fromARGB(255, grey, grey, grey);
  }
  final offset = y * image.bytesPerLine + x * 4;
  return Color.fromARGB(
    255,
    pixels[offset],
    pixels[offset + 1],
    pixels[offset + 2],
  );
}

List<Color> _samples(
  PdfPageImage image,
  (int, int, int, int) area,
  int maxSamples,
) {
  final (left, top, right, bottom) = area;
  final step = _step((right - left) * (bottom - top), maxSamples);
  return [
    for (var y = top; y < bottom; y += step)
      for (var x = left; x < right; x += step) _pixel(image, x, y),
  ];
}

/// Pixels of [outer] that are not in [inner].
List<Color> _ringSamples(
  PdfPageImage image,
  (int, int, int, int) outer,
  (int, int, int, int) inner,
  int maxSamples,
) {
  final (left, top, right, bottom) = outer;
  final (innerLeft, innerTop, innerRight, innerBottom) = inner;
  final area =
      (right - left) * (bottom - top) -
      (innerRight - innerLeft) * (innerBottom - innerTop);
  final step = _step(area, maxSamples);
  final samples = <Color>[];
  for (var y = top; y < bottom; y += step) {
    final insideRows = y >= innerTop && y < innerBottom;
    for (var x = left; x < right; x += step) {
      if (insideRows && x >= innerLeft && x < innerRight) continue;
      samples.add(_pixel(image, x, y));
    }
  }
  return samples;
}

/// The per-channel median of [colours]; null when there are none.
Color? _median(List<Color> colours) {
  if (colours.isEmpty) return null;
  int channel(int Function(Color colour) of) {
    final values = [for (final colour in colours) of(colour)]..sort();
    return values[values.length ~/ 2];
  }

  return Color.fromARGB(255, channel(_red), channel(_green), channel(_blue));
}

int _red(Color colour) => (colour.toARGB32() >> 16) & 0xFF;
int _green(Color colour) => (colour.toARGB32() >> 8) & 0xFF;
int _blue(Color colour) => colour.toARGB32() & 0xFF;

/// Rec. 601 brightness (0 to 255).
double _brightness(Color colour) =>
    0.299 * _red(colour) + 0.587 * _green(colour) + 0.114 * _blue(colour);

/// The least difference in brightness between text and background that
/// counts as text.
const _minContrast = 40;

/// The share of the box's pixels taken as the text's strokes.
const _strokeShare = 0.1;

Color _strokes(
  PdfPageImage image,
  (int, int, int, int) area,
  Color background,
  int maxSamples,
) {
  final base = _brightness(background);
  final samples = _samples(image, area, maxSamples)
    ..sort(
      (a, b) => (_brightness(b) - base).abs().compareTo(
        (_brightness(a) - base).abs(),
      ),
    );
  final readable = base > 128
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);
  if (samples.isEmpty ||
      (_brightness(samples.first) - base).abs() < _minContrast) {
    return readable;
  }
  final count = math.max(1, (samples.length * _strokeShare).round());
  var red = 0;
  var green = 0;
  var blue = 0;
  for (final colour in samples.take(count)) {
    red += _red(colour);
    green += _green(colour);
    blue += _blue(colour);
  }
  return Color.fromARGB(
    255,
    (red / count).round(),
    (green / count).round(),
    (blue / count).round(),
  );
}
