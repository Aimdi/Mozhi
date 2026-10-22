import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/models/models.dart';

/// One translated paragraph drawn over the photo, in pixels of the image
/// its [TextLayout] describes: the paragraph's area [fill]ed with the
/// colour around the original text, and the translation in [painter]
/// (already laid out to fit [textArea]).
class OverlayLabel {
  new({
    required this.index,
    required this.original,
    required this.translation,
    required this.fill,
    required this.textArea,
    required this.background,
    required this.foreground,
    required this.blur,
    required this.painter,
  });

  /// The paragraph's index in [TextLayout.paragraphs].
  final int index;
  final String original;
  final String translation;

  /// The area that hides the original text (the paragraph's box, a little
  /// larger).
  final Rect fill;

  /// Where the translation is laid out (centred vertically).
  final Rect textArea;
  final Color background;
  final Color foreground;

  /// Softens the edges of [fill] (a blur sigma in image pixels).
  final double blur;
  final TextPainter painter;

  /// Paints the label on [canvas], whose units are image pixels.
  void paint(Canvas canvas) {
    final paint = Paint()..color = background;
    if (blur > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(fill, Radius.circular(blur * 2)),
        paint,
      )
      ..save()
      ..clipRect(fill);
    painter.paint(
      canvas,
      Offset(
        textArea.left,
        textArea.top + math.max(0, (textArea.height - painter.height) / 2),
      ),
    );
    canvas.restore();
  }

  void dispose() => painter.dispose();
}

/// Lays out the overlay of [translations] (one per paragraph of [layout];
/// empty ones are skipped) for text in [direction] and [locale] (the
/// target language's), in [style] (a font; its size and colour are
/// replaced).
///
/// Each translation gets the largest font size that fits its paragraph's
/// box (at most the original line height, so it never looks larger than
/// the original), wrapped within the box and never broken inside a word
/// when that can be avoided; text that does not fit even at the smallest
/// size ends with an ellipsis. It is drawn in the paragraph's text colour
/// when that contrasts with the background (3:1), else in black or white.
/// System text scaling does not apply: the text must fit the photo (it is
/// read at full size in the paragraph's sheet).
List<OverlayLabel> layoutOverlay(
  TextLayout layout,
  List<String> translations, {
  required TextDirection direction,
  Locale? locale,
  TextStyle style = const TextStyle(),
}) {
  final bounds = Rect.fromLTWH(
    0,
    0,
    layout.width.toDouble(),
    layout.height.toDouble(),
  );
  return [
    for (var i = 0; i < layout.paragraphs.length; i++)
      if (i < translations.length && translations[i].trim().isNotEmpty)
        _label(
          i,
          layout.paragraphs[i],
          translations[i].trim(),
          bounds: bounds,
          direction: direction,
          locale: locale,
          style: style,
        ),
  ];
}

/// Line height of the translation (times the font size).
const _lineHeight = 1.15;

/// Background when the recognizer reported none: an almost opaque white.
const overlayFallbackBackground = Color(0xF2FFFFFF);

OverlayLabel _label(
  int index,
  TextParagraph paragraph,
  String translation, {
  required Rect bounds,
  required TextDirection direction,
  required Locale? locale,
  required TextStyle style,
}) {
  final pitch = paragraph.linePitch;
  final pad = math.max(1.5, pitch * 0.15);
  final fill = paragraph.box.inflate(pad).intersect(bounds);
  final textArea = paragraph.box.inflate(pad * 0.5).intersect(bounds);
  final background = paragraph.background ?? overlayFallbackBackground;
  final foreground = overlayTextColor(background, paragraph.foreground);
  final align = switch (paragraph.alignment) {
    TextParagraphAlignment.left => TextAlign.left,
    TextParagraphAlignment.right => TextAlign.right,
    TextParagraphAlignment.center => TextAlign.center,
    TextParagraphAlignment.unknown when paragraph.lineCount <= 1 =>
      TextAlign.center,
    TextParagraphAlignment.unknown => TextAlign.start,
  };
  return OverlayLabel(
    index: index,
    original: paragraph.text,
    translation: translation,
    fill: fill,
    textArea: textArea,
    background: background,
    foreground: foreground,
    blur: pad * 0.6,
    painter: fitOverlayText(
      translation,
      style.copyWith(color: foreground),
      textArea.size,
      maxFontSize: pitch,
      minFontSize: math.max(3, pitch * 0.3),
      align: align,
      direction: direction,
      locale: locale,
    ),
  );
}

/// The colour to draw text in over [background]: [sampled] (the original
/// text's colour) when it contrasts enough (3:1), else black or white,
/// whichever contrasts more. Always opaque.
Color overlayTextColor(Color background, Color? sampled) {
  if (sampled != null && contrastRatio(sampled, background) >= 3) {
    return sampled.withValues(alpha: 1);
  }
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  return contrastRatio(black, background) >= contrastRatio(white, background)
      ? black
      : white;
}

/// WCAG contrast ratio of [a] and [b] (1 to 21).
double contrastRatio(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
}

/// A [TextPainter] of [text] laid out [area] wide at the largest font size
/// from [minFontSize] to [maxFontSize] at which it fits [area] without
/// breaking a word (searched to a fraction of a pixel); when even
/// [minFontSize] does not fit, as many lines as fit at that size, the last
/// ending in an ellipsis.
TextPainter fitOverlayText(
  String text,
  TextStyle style,
  Size area, {
  required double maxFontSize,
  required double minFontSize,
  TextAlign align = TextAlign.start,
  TextDirection direction = TextDirection.ltr,
  Locale? locale,
}) {
  final width = math.max(1, area.width).toDouble();
  final max = math.max(minFontSize, maxFontSize);
  TextPainter make(double size, {int? maxLines}) => TextPainter(
    text: TextSpan(
      text: text,
      style: style.copyWith(
        fontSize: size,
        height: _lineHeight,
        locale: locale,
      ),
    ),
    textAlign: align,
    textDirection: direction,
    locale: locale,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
    textScaler: TextScaler.noScaling,
  )..layout(minWidth: width, maxWidth: width);

  // The longest word must fit on a line: text width grows with the font
  // size, so one measurement at 100 px tells its width at any size.
  final word = _longestWord(text);
  var wordAt100 = 0.0;
  if (word.isNotEmpty) {
    final probe = TextPainter(
      text: TextSpan(
        text: word,
        style: style.copyWith(fontSize: 100, locale: locale),
      ),
      textDirection: direction,
      locale: locale,
      textScaler: TextScaler.noScaling,
    )..layout();
    wordAt100 = probe.width;
    probe.dispose();
  }
  bool fits(TextPainter painter, double size) =>
      painter.height <= area.height + 0.5 &&
      wordAt100 * size / 100 <= width + 0.5;

  final largest = make(max);
  if (fits(largest, max)) return largest;
  largest.dispose();
  TextPainter? best;
  var low = minFontSize;
  var high = max;
  for (var step = 0; step < 10 && high - low > 0.25; step++) {
    final middle = (low + high) / 2;
    final painter = make(middle);
    if (fits(painter, middle)) {
      best?.dispose();
      best = painter;
      low = middle;
    } else {
      painter.dispose();
      high = middle;
    }
  }
  if (best != null) return best;
  final smallest = make(minFontSize);
  if (fits(smallest, minFontSize)) return smallest;
  smallest.dispose();
  final lines = math.max(1, area.height ~/ (minFontSize * _lineHeight));
  return make(minFontSize, maxLines: lines);
}

/// The longest whitespace-separated word of [text] that cannot be broken
/// (words with Chinese, Japanese, Thai, ... characters break anywhere).
String _longestWord(String text) {
  var longest = '';
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.length > longest.length && !_breaksAnywhere.hasMatch(word)) {
      longest = word;
    }
  }
  return longest;
}

final _breaksAnywhere = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
  r'\p{Script=Hangul}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}'
  r'\p{Script=Myanmar}]',
  unicode: true,
);
