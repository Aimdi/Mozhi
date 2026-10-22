import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:meta/meta.dart';

/// Two points a line's baseline passes through, in image pixels.
typedef OcrBaseline = ({int x1, int y1, int x2, int y2});

/// A rectangle in image pixels: from the top-left corner of the first
/// pixel ([left], [top]) to the bottom-right corner of the last one
/// ([right], [bottom], exclusive), as Tesseract reports boxes.
@immutable
final class OcrBox {
  const new(this.left, this.top, this.right, this.bottom);

  /// `[left, top, right, bottom]`.
  factory fromJson(Object? json) {
    if (json is! List || json.length != 4) {
      throw FormatException('Not a box: $json');
    }
    final [left, top, right, bottom] = [
      for (final value in json) (value as num).toInt(),
    ];
    return OcrBox(left, top, right, bottom);
  }

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;

  @override
  bool operator ==(Object other) =>
      other is OcrBox &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'OcrBox($left, $top, $right, $bottom)';
}

/// One recognised word.
@immutable
final class OcrWord {
  const new({required this.text, required this.box, this.confidence = 0});

  factory fromJson(Map<String, Object?> json) => OcrWord(
    text: json['text']! as String,
    box: OcrBox.fromJson(json['box']),
    confidence: _int(json['confidence']),
  );

  final String text;
  final OcrBox box;

  /// 0 to 100.
  final int confidence;

  @override
  bool operator ==(Object other) =>
      other is OcrWord &&
      other.text == text &&
      other.box == box &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(text, box, confidence);

  @override
  String toString() => 'OcrWord($text, $box, $confidence%)';
}

/// One line of text: its [words] (when they were asked for) and the
/// baseline the letters sit on.
@immutable
final class OcrLine {
  const new({
    required this.text,
    required this.box,
    this.confidence = 0,
    this.baseline,
    this.words = const [],
  });

  factory fromJson(Map<String, Object?> json) {
    final baseline = json['baseline'];
    return OcrLine(
      text: json['text']! as String,
      box: OcrBox.fromJson(json['box']),
      confidence: _int(json['confidence']),
      baseline: switch (baseline) {
        null => null,
        [final num x1, final num y1, final num x2, final num y2] => (
          x1: x1.toInt(),
          y1: y1.toInt(),
          x2: x2.toInt(),
          y2: y2.toInt(),
        ),
        _ => throw FormatException('Not a baseline: $baseline'),
      },
      words: [
        for (final word in (json['words'] as List?) ?? const <Object?>[])
          OcrWord.fromJson(word! as Map<String, Object?>),
      ],
    );
  }

  /// The line's text in reading order (also for right-to-left scripts).
  final String text;
  final OcrBox box;

  /// 0 to 100.
  final int confidence;

  /// The line the letters sit on; null when unknown.
  final OcrBaseline? baseline;
  final List<OcrWord> words;

  /// How many degrees the baseline turns clockwise from level (image y
  /// grows downwards); 0 when unknown.
  double get angle {
    final line = baseline;
    if (line == null || line.x2 == line.x1 && line.y2 == line.y1) return 0;
    return math.atan2(line.y2 - line.y1, line.x2 - line.x1) * 180 / math.pi;
  }

  @override
  bool operator ==(Object other) =>
      other is OcrLine &&
      other.text == text &&
      other.box == box &&
      other.confidence == confidence &&
      other.baseline == baseline &&
      listEquals(other.words, words);

  @override
  int get hashCode =>
      Object.hash(text, box, confidence, baseline, Object.hashAll(words));

  @override
  String toString() => 'OcrLine($text, $box, $confidence%)';
}

/// How a paragraph's lines are aligned.
enum OcrAlignment {
  left,
  center,
  right,
  unknown;

  static OcrAlignment parse(Object? value) =>
      values.where((alignment) => alignment.name == value).firstOrNull ??
      unknown;
}

/// One paragraph: its [lines] in reading order, and the colours of its
/// background and text in the image.
@immutable
final class OcrParagraph {
  const new({
    required this.box,
    required this.lines,
    this.confidence = 0,
    this.isLeftToRight = true,
    this.alignment = OcrAlignment.unknown,
    this.background,
    this.foreground,
  });

  factory fromJson(Map<String, Object?> json) => OcrParagraph(
    box: OcrBox.fromJson(json['box']),
    confidence: _int(json['confidence']),
    isLeftToRight: json['ltr'] as bool? ?? true,
    alignment: OcrAlignment.parse(json['align']),
    background: (json['background'] as num?)?.toInt(),
    foreground: (json['foreground'] as num?)?.toInt(),
    lines: [
      for (final line in (json['lines'] as List?) ?? const <Object?>[])
        OcrLine.fromJson(line! as Map<String, Object?>),
    ],
  );

  final OcrBox box;
  final List<OcrLine> lines;

  /// 0 to 100.
  final int confidence;

  /// False for right-to-left scripts (Arabic, Hebrew, ...).
  final bool isLeftToRight;
  final OcrAlignment alignment;

  /// The median colour (`0xRRGGBB`) of the pixels in [box] that are not
  /// text, null when unknown.
  final int? background;

  /// The median colour (`0xRRGGBB`) of the text's pixels, null when
  /// unknown.
  final int? foreground;

  /// The lines, separated by `\n`.
  String get text => lines.map((line) => line.text).join('\n');

  @override
  bool operator ==(Object other) =>
      other is OcrParagraph &&
      other.box == box &&
      listEquals(other.lines, lines) &&
      other.confidence == confidence &&
      other.isLeftToRight == isLeftToRight &&
      other.alignment == alignment &&
      other.background == background &&
      other.foreground == foreground;

  @override
  int get hashCode => Object.hash(
    box,
    Object.hashAll(lines),
    confidence,
    isLeftToRight,
    alignment,
    background,
    foreground,
  );

  @override
  String toString() => 'OcrParagraph(${lines.length} lines, $box)';
}

/// A block of text found by layout analysis (a column, a sign, a caption).
@immutable
final class OcrBlock {
  const new({
    required this.box,
    required this.paragraphs,
    this.confidence = 0,
    this.orientation = 0,
    this.isVertical = false,
    this.deskewAngle = 0,
  });

  factory fromJson(Map<String, Object?> json) => OcrBlock(
    box: OcrBox.fromJson(json['box']),
    confidence: _int(json['confidence']),
    orientation: _int(json['orientation']),
    isVertical: json['vertical'] as bool? ?? false,
    deskewAngle: (json['deskew'] as num?)?.toDouble() ?? 0,
    paragraphs: [
      for (final paragraph
          in (json['paragraphs'] as List?) ?? const <Object?>[])
        OcrParagraph.fromJson(paragraph! as Map<String, Object?>),
    ],
  );

  final OcrBox box;
  final List<OcrParagraph> paragraphs;

  /// 0 to 100.
  final int confidence;

  /// Clockwise rotation of the text from upright as layout analysis sees
  /// it: 0, 90, 180 or 270 (without orientation detection, which needs
  /// Tesseract's legacy engine, almost always 0).
  final int orientation;

  /// Written top to bottom (vertical Chinese, Japanese, Korean).
  final bool isVertical;

  /// Degrees to rotate the block anti-clockwise for it to be level.
  final double deskewAngle;

  @override
  bool operator ==(Object other) =>
      other is OcrBlock &&
      other.box == box &&
      listEquals(other.paragraphs, paragraphs) &&
      other.confidence == confidence &&
      other.orientation == orientation &&
      other.isVertical == isVertical &&
      other.deskewAngle == deskewAngle;

  @override
  int get hashCode => Object.hash(
    box,
    Object.hashAll(paragraphs),
    confidence,
    orientation,
    isVertical,
    deskewAngle,
  );

  @override
  String toString() => 'OcrBlock(${paragraphs.length} paragraphs, $box)';
}

/// Where the recognised text is in an image of [width] x [height] pixels
/// (the image given to recognition): its [blocks] in reading order.
@immutable
final class OcrLayout {
  const new({required this.width, required this.height, required this.blocks});

  /// The `width`, `height` and `blocks` of
  /// `mozhi_tesseract_recognize_layout`'s JSON. Throws [FormatException]
  /// (or a [TypeError]) for anything else.
  factory fromJson(Map<String, Object?> json) => OcrLayout(
    width: _int(json['width']),
    height: _int(json['height']),
    blocks: [
      for (final block in (json['blocks'] as List?) ?? const <Object?>[])
        OcrBlock.fromJson(block! as Map<String, Object?>),
    ],
  );

  final int width;
  final int height;
  final List<OcrBlock> blocks;

  /// Every paragraph, in reading order.
  Iterable<OcrParagraph> get paragraphs =>
      blocks.expand((block) => block.paragraphs);

  bool get isEmpty => blocks.every((block) => block.paragraphs.isEmpty);

  @override
  bool operator ==(Object other) =>
      other is OcrLayout &&
      other.width == width &&
      other.height == height &&
      listEquals(other.blocks, blocks);

  @override
  int get hashCode => Object.hash(width, height, Object.hashAll(blocks));

  @override
  String toString() =>
      'OcrLayout(${width}x$height, ${blocks.length} blocks, '
      '${paragraphs.length} paragraphs)';
}

int _int(Object? value) => (value as num?)?.toInt() ?? 0;
