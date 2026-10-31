import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:intl/intl.dart' show Bidi;
import 'package:mozhi/documents/pdf/pdf_pages.dart';
import 'package:mozhi/image_translate/models/models.dart';

/// The text layer of a PDF page ([PdfPages.readText]) as the layout text
/// recognition gives ([TextLayout]): its lines grouped into paragraphs,
/// with their boxes, line counts and alignment, so a page read from its
/// text layer is covered and redrawn exactly like a page read with text
/// recognition.
abstract final class PdfTextLayer {
  /// A page's text layer is used when it has at least this many letters
  /// and digits; a page with fewer (a scan with only a page number in its
  /// text layer, a picture with a caption) is read with text recognition.
  static const minCharacters = 20;

  /// A text layer whose characters are this share or more of unknown,
  /// private-use or control characters (fonts without a character map:
  /// the file draws glyphs it cannot name) is read with text recognition.
  static const maxGarbledShare = 0.1;

  /// What a paragraph read from the text layer is trusted as (0 to 100).
  static const confidence = 100;

  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _garbled = RegExp(
    r'[\uFFFD\uE000-\uF8FF\x00-\x08\x0B\x0C\x0E-\x1F]',
  );
  static final _space = RegExp(r'\s');

  /// Whether [lines] (a page's text layer) carry the page's text: enough
  /// letters and digits ([minCharacters]) and few unreadable characters
  /// ([maxGarbledShare]).
  static bool isUsable(List<PdfTextLine>? lines) {
    if (lines == null || lines.isEmpty) return false;
    var letters = 0;
    var garbled = 0;
    var visible = 0;
    for (final line in lines) {
      if (line.rect.isEmpty) continue;
      for (final rune in line.text.runes) {
        final char = String.fromCharCode(rune);
        if (_space.hasMatch(char)) continue;
        visible++;
        if (_letterOrDigit.hasMatch(char)) {
          letters++;
        } else if (_garbled.hasMatch(char)) {
          garbled++;
        }
      }
    }
    return letters >= minCharacters &&
        visible > 0 &&
        garbled / visible < maxGarbledShare;
  }

  /// [lines] of a page of [page] points as a layout of [width] x [height]
  /// pixels (the page as rendered): lines without letters or digits, or
  /// without a box on the page, are left out; the others are grouped into
  /// paragraphs in their order ([groupLines]).
  static TextLayout layoutOf(
    List<PdfTextLine> lines, {
    required Size page,
    required int width,
    required int height,
  }) {
    final bounds = Rect.fromLTWH(0, 0, page.width, page.height);
    final kept = <PdfTextLine>[];
    for (final line in lines) {
      if (!_letterOrDigit.hasMatch(line.text)) continue;
      final rect = line.rect.intersect(bounds);
      if (rect.width <= 0 || rect.height <= 0) continue;
      kept.add(PdfTextLine(text: line.text.trim(), rect: rect));
    }
    final scaleX = page.width > 0 ? width / page.width : 1.0;
    final scaleY = page.height > 0 ? height / page.height : 1.0;
    return TextLayout(
      width: width,
      height: height,
      paragraphs: [
        for (final group in groupLines(kept))
          _paragraphOf(group, scaleX, scaleY),
      ],
    );
  }

  /// [lines] (in the file's order, the reading order of most files) cut
  /// into paragraphs: a line goes on the paragraph of the line before it
  /// when it is below it, of about the same height, overlaps it
  /// horizontally and the gap between them is small (at most
  /// [maxFirstGap] of a line's height, and not much more than the
  /// paragraph's first gap: a wider gap starts a paragraph).
  static List<List<PdfTextLine>> groupLines(List<PdfTextLine> lines) {
    final groups = <List<PdfTextLine>>[];
    double? firstGap;
    for (final line in lines) {
      final current = groups.isEmpty ? null : groups.last;
      final gap = current == null ? null : _joinGap(current, line, firstGap);
      if (current == null || gap == null) {
        groups.add([line]);
        firstGap = null;
      } else {
        current.add(line);
        firstGap ??= gap;
      }
    }
    return groups;
  }

  /// The largest gap between two lines of one paragraph, in line heights.
  static const maxFirstGap = 0.8;

  /// How much wider than its first gap a later gap of a paragraph may be,
  /// in line heights.
  static const gapTolerance = 0.35;

  /// The gap (in line heights) at which [next] joins [paragraph], or null
  /// when it starts a paragraph.
  static double? _joinGap(
    List<PdfTextLine> paragraph,
    PdfTextLine next,
    double? firstGap,
  ) {
    final previous = paragraph.last.rect;
    final rect = next.rect;
    final low = math.min(previous.height, rect.height);
    final high = math.max(previous.height, rect.height);
    if (low <= 0 || high / low > 1.4) return null;
    final overlap =
        math.min(previous.right, rect.right) -
        math.max(previous.left, rect.left);
    if (overlap <= 0) return null;
    final gap = (rect.top - previous.bottom) / low;
    if (gap < -0.3 || gap > maxFirstGap) return null;
    if (firstGap != null && gap > firstGap + gapTolerance) return null;
    return gap;
  }

  static TextParagraph _paragraphOf(
    List<PdfTextLine> lines,
    double scaleX,
    double scaleY,
  ) {
    var box = lines.first.rect;
    for (final line in lines.skip(1)) {
      box = box.expandToInclude(line.rect);
    }
    final text = TextParagraph.joinLines([for (final line in lines) line.text]);
    final rtl = Bidi.detectRtlDirectionality(text);
    return TextParagraph(
      text: text,
      box: Rect.fromLTRB(
        box.left * scaleX,
        box.top * scaleY,
        box.right * scaleX,
        box.bottom * scaleY,
      ),
      lineCount: lines.length,
      alignment: alignmentOf(lines, rightToLeft: rtl),
      isRightToLeft: rtl,
      confidence: confidence,
    );
  }

  /// How [lines] (one paragraph) are aligned, as seen: a single line by its
  /// direction; more by which of their edges (the last line's left out,
  /// it is often shorter) or centres line up, within half a line's height.
  static TextParagraphAlignment alignmentOf(
    List<PdfTextLine> lines, {
    bool rightToLeft = false,
  }) {
    final start = rightToLeft
        ? TextParagraphAlignment.right
        : TextParagraphAlignment.left;
    if (lines.length < 2) return start;
    final height =
        lines.fold<double>(0, (sum, line) => sum + line.rect.height) /
        lines.length;
    final tolerance = height / 2;
    bool lineUp(double Function(Rect rect) edge, {bool skipLast = true}) {
      final measured = skipLast && lines.length > 2
          ? lines.sublist(0, lines.length - 1)
          : lines;
      final first = edge(measured.first.rect);
      return measured.every(
        (line) => (edge(line.rect) - first).abs() <= tolerance,
      );
    }

    final left = lineUp((rect) => rect.left);
    final right = lineUp((rect) => rect.right);
    final centre = lineUp((rect) => rect.center.dx, skipLast: false);
    if (rightToLeft) {
      if (right) return TextParagraphAlignment.right;
      if (centre && !left) return TextParagraphAlignment.center;
      if (left) return TextParagraphAlignment.left;
    } else {
      if (left) return TextParagraphAlignment.left;
      if (centre && !right) return TextParagraphAlignment.center;
      if (right) return TextParagraphAlignment.right;
    }
    return centre ? TextParagraphAlignment.center : start;
  }
}
