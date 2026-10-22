import 'dart:ui' show Color, Rect;

import 'package:flutter/foundation.dart';

/// How the lines of a recognised paragraph are aligned in the image (as
/// seen, whatever the script's direction).
enum TextParagraphAlignment { left, center, right, unknown }

/// One paragraph of text recognised in an image, and where it is.
@immutable
class TextParagraph {
  const new({
    required this.text,
    required this.box,
    this.lineCount = 1,
    this.alignment = TextParagraphAlignment.unknown,
    this.isRightToLeft = false,
    this.background,
    this.foreground,
    this.confidence,
  });

  /// The paragraph's text with its lines joined (see [joinLines]): what is
  /// translated.
  final String text;

  /// Where it is, in pixels of the image [TextLayout] describes.
  final Rect box;

  /// How many lines it has in the image (sizes the translation's font).
  final int lineCount;
  final TextParagraphAlignment alignment;

  /// Written right to left in the image (Arabic, Hebrew, ...).
  final bool isRightToLeft;

  /// The colour around the text (opaque), null when unknown.
  final Color? background;

  /// The colour of the text (opaque), null when unknown.
  final Color? foreground;

  /// 0 to 100, null when unknown.
  final int? confidence;

  /// The distance between two lines (the height of one line for a single
  /// line), in image pixels.
  double get linePitch => box.height / (lineCount < 1 ? 1 : lineCount);

  TextParagraph withText(String text) => TextParagraph(
    text: text,
    box: box,
    lineCount: lineCount,
    alignment: alignment,
    isRightToLeft: isRightToLeft,
    background: background,
    foreground: foreground,
    confidence: confidence,
  );

  /// Joins the [lines] of a paragraph into running text, so a sentence that
  /// wraps in the image is translated as one: a word hyphenated at a line
  /// end is joined again, lines in scripts without spaces (Chinese,
  /// Japanese, Thai, ...) are joined without one, others with a space. A
  /// line ending a sentence (`.`, `:`, `!`, `?`, ...) or a line starting
  /// with a list marker keeps its line break.
  static String joinLines(List<String> lines) {
    final buffer = StringBuffer();
    String? previous;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final before = previous;
      if (before == null) {
        buffer.write(line);
      } else if (_endsSentence.hasMatch(before) ||
          _startsListItem.hasMatch(line)) {
        buffer
          ..write('\n')
          ..write(line);
      } else if (_hyphenated.hasMatch(before) &&
          _startsLowercase.hasMatch(line)) {
        // "transla-" + "tion": drop the hyphen the line break needed.
        final text = buffer.toString();
        buffer
          ..clear()
          ..write(text.substring(0, text.length - 1))
          ..write(line);
      } else if (_withoutSpaces.hasMatch(
            String.fromCharCode(before.runes.last),
          ) &&
          _withoutSpaces.hasMatch(String.fromCharCode(line.runes.first))) {
        buffer.write(line);
      } else {
        buffer
          ..write(' ')
          ..write(line);
      }
      previous = line;
    }
    return buffer.toString();
  }

  static final _endsSentence = RegExp(r'[.!?:;…。！？：；]["”’»«)\]]*$');
  static final _startsListItem = RegExp(r'^(?:[•·▪◦‣*–—-]\s|\d{1,3}[.)]\s)');
  static final _hyphenated = RegExp(r'\p{L}[-‐­]$', unicode: true);
  static final _startsLowercase = RegExp(r'^\p{Ll}', unicode: true);
  static final _withoutSpaces = RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
    r'\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}'
    r'\p{Script=Tibetan}　-〿＀-｠]',
    unicode: true,
  );

  @override
  bool operator ==(Object other) =>
      other is TextParagraph &&
      other.text == text &&
      other.box == box &&
      other.lineCount == lineCount &&
      other.alignment == alignment &&
      other.isRightToLeft == isRightToLeft &&
      other.background == background &&
      other.foreground == foreground &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(
    text,
    box,
    lineCount,
    alignment,
    isRightToLeft,
    background,
    foreground,
    confidence,
  );

  @override
  String toString() => 'TextParagraph($text, $box)';
}

/// Where the text recognised in an image is: its [paragraphs] in reading
/// order, in pixels of the image as it was read ([width] x [height], the
/// photo upright, possibly scaled down).
///
/// The paragraphs are translated in one request: [text] joins them with
/// blank lines ([paragraphSeparator]), which every engine keeps, and
/// [splitParagraphs] / [alignTranslation] take the translation apart again.
@immutable
class TextLayout {
  const new({
    required this.width,
    required this.height,
    required this.paragraphs,
  });

  final int width;
  final int height;
  final List<TextParagraph> paragraphs;

  /// Between two paragraphs of [text].
  static const paragraphSeparator = '\n\n';

  bool get isEmpty => paragraphs.isEmpty;

  /// The paragraphs, separated by blank lines: the text to translate.
  String get text => paragraphs.map((p) => p.text).join(paragraphSeparator);

  /// This layout with the paragraphs of [text] (an edited [text]), or null
  /// when it does not have as many paragraphs.
  TextLayout? withText(String text) {
    final parts = splitParagraphs(text);
    if (parts.length != paragraphs.length || parts.isEmpty) return null;
    return TextLayout(
      width: width,
      height: height,
      paragraphs: [
        for (var i = 0; i < parts.length; i++) paragraphs[i].withText(parts[i]),
      ],
    );
  }

  /// The paragraphs of [text]: the parts between blank lines, trimmed,
  /// without empty ones.
  static List<String> splitParagraphs(String text) => [
    for (final part in text.split(_blankLine))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  static final _blankLine = RegExp(r'\n[ \t\r\f\v ]*\n\s*');

  /// The translation of each paragraph in [translation] (the translation of
  /// [text]): its [splitParagraphs] when there are as many as
  /// [paragraphs]. Otherwise (an engine merged or split paragraphs) its
  /// lines, and if there are too few its sentences, are spread over the
  /// paragraphs by their position in the text: paragraph lengths in the
  /// source and in the translation are roughly proportional. A paragraph
  /// that gets nothing has an empty translation (it is not covered).
  List<String> alignTranslation(String translation) {
    final count = paragraphs.length;
    final parts = splitParagraphs(translation);
    if (parts.length == count || count == 0) return parts.take(count).toList();
    if (count == 1) return [parts.join('\n')];
    var units = [
      for (final part in parts)
        for (final line in part.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
    ];
    if (units.length < count) {
      units = [
        for (final unit in units)
          for (final sentence in unit.split(_sentenceEnd))
            if (sentence.trim().isNotEmpty) sentence.trim(),
      ];
    }
    return _spread(units);
  }

  /// [units] (lines or sentences of a translation, in order) grouped into
  /// one part per paragraph, keeping their order: the grouping whose parts'
  /// shares of the translation's length are closest to the paragraphs'
  /// shares of the source's length. Every paragraph gets a unit while there
  /// are enough.
  List<String> _spread(List<String> units) {
    final count = paragraphs.length;
    // Paragraphs always have text (at least a letter or digit).
    final sourceTotal = paragraphs.fold<int>(1, (a, p) => a + p.text.length);
    final shares = [for (final p in paragraphs) p.text.length / sourceTotal];
    final prefix = [0];
    for (final unit in units) {
      prefix.add(prefix.last + unit.length);
    }
    final total = prefix.last == 0 ? 1 : prefix.last;
    final nonEmpty = units.length >= count;
    final m = units.length;
    const infinite = double.infinity;
    // cost[j][b]: best cost of the first j paragraphs taking units [0, b);
    // from[j][b]: where paragraph j - 1's units start then.
    final cost = [
      for (var j = 0; j <= count; j++) List.filled(m + 1, infinite),
    ];
    final from = [for (var j = 0; j <= count; j++) List.filled(m + 1, 0)];
    cost[0][0] = 0;
    for (var j = 1; j <= count; j++) {
      for (var b = 0; b <= m; b++) {
        for (var a = 0; a <= b; a++) {
          if (nonEmpty && a == b) continue;
          final before = cost[j - 1][a];
          if (before == infinite) continue;
          final share = (prefix[b] - prefix[a]) / total;
          final value = before + (share - shares[j - 1]).abs();
          if (value < cost[j][b]) {
            cost[j][b] = value;
            from[j][b] = a;
          }
        }
      }
    }
    final aligned = List.filled(count, '');
    var end = m;
    for (var j = count; j > 0; j--) {
      final start = from[j][end];
      aligned[j - 1] = units.sublist(start, end).join(' ');
      end = start;
    }
    return aligned;
  }

  // After a sentence end and its spaces (kept with the sentence), or after
  // CJK and other full stops.
  static final _sentenceEnd = RegExp(r'(?<=[.!?…])\s+|(?<=[。！？।؟])');

  @override
  bool operator ==(Object other) =>
      other is TextLayout &&
      other.width == width &&
      other.height == height &&
      listEquals(other.paragraphs, paragraphs);

  @override
  int get hashCode => Object.hash(width, height, Object.hashAll(paragraphs));

  @override
  String toString() =>
      'TextLayout(${width}x$height, ${paragraphs.length} paragraphs)';
}
