import 'package:meta/meta.dart';

/// One part of a long text that is translated on its own.
@immutable
class TextChunk {
  const new({required this.text, this.separator = ''});

  /// The part, without leading or trailing whitespace.
  final String text;

  /// The whitespace between this part and the next one, exactly as it is in
  /// the original text. Empty for the last part, and between parts that were
  /// cut where the text has no whitespace (after a CJK full stop, or inside
  /// an overlong word).
  final String separator;

  @override
  bool operator ==(Object other) =>
      other is TextChunk && other.text == text && other.separator == separator;

  @override
  int get hashCode => Object.hash(text, separator);

  @override
  String toString() =>
      'TextChunk(${text.length} chars, '
      'separator: ${separator.length} chars)';
}

/// Splits a long text into parts of at most `maxChars` characters for
/// translation, preferring (in this order) paragraph boundaries (blank
/// lines), line breaks, sentence ends and word boundaries; a part is only
/// cut inside a word when a single word is longer than `maxChars`.
///
/// Fenced code blocks (```` ``` ```` or `~~~`) are never cut: a block longer
/// than `maxChars` becomes a part of its own that is longer than the limit.
///
/// Parts are balanced: a text slightly over the limit becomes two parts of
/// about half its length rather than a full one and a short rest.
///
/// The whitespace between parts is kept byte for byte in
/// [TextChunk.separator], so [join] restores the layout around translated
/// parts. Whitespace before the first and after the last part is dropped
/// (as translations are trimmed).
abstract final class ParagraphChunker {
  /// Splits [text] (see the class documentation). Returns an empty list for
  /// blank text and a single part when the trimmed text fits [maxChars].
  /// Throws an [ArgumentError] when [maxChars] is less than 1.
  static List<TextChunk> split(String text, {required int maxChars}) {
    if (maxChars < 1) {
      throw ArgumentError.value(maxChars, 'maxChars', 'Must be at least 1');
    }
    final start = text.length - text.trimLeft().length;
    final end = text.trimRight().length;
    if (end <= start) return const [];
    final spans = _Splitter(text, start, end, maxChars).split();
    return [
      for (var i = 0; i < spans.length; i++)
        TextChunk(
          text: text.substring(spans[i].start, spans[i].end),
          separator: i + 1 < spans.length
              ? text.substring(spans[i].end, spans[i + 1].start)
              : '',
        ),
    ];
  }

  /// Joins [parts] (one per chunk, in order, e.g. their translations) with
  /// the separators of [chunks]. Throws an [ArgumentError] when the lengths
  /// differ.
  static String join(List<TextChunk> chunks, List<String> parts) {
    if (parts.length != chunks.length) {
      throw ArgumentError.value(
        parts.length,
        'parts',
        'Expected ${chunks.length} parts',
      );
    }
    final buffer = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      buffer.write(parts[i]);
      if (i + 1 < parts.length) buffer.write(chunks[i].separator);
    }
    return buffer.toString();
  }
}

/// A place where the text may be cut: the whitespace from `start` to `end`
/// (empty after a CJK full stop) goes into the separator.
typedef _Cut = ({int start, int end, int level});

typedef _Span = ({int start, int end});

/// Cut levels, best first.
const _paragraph = 3;
const _line = 2;
const _sentence = 1;
const _word = 0;

final _whitespace = RegExp(r'\s+');
final _lineBreak = RegExp(r'\r\n|\r|\n');
final _fenceLine = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// Full stops after which CJK text continues without a space.
final _cjkSentenceEnd = RegExp('[。！？｡．][」』）〉》】"”’]*');

/// Closing quotes and brackets that may follow a sentence end.
const _closers = '"\'”’»›)]}」』）〉》】';

/// Sentence-ending punctuation (Latin, CJK, Arabic, Devanagari, Urdu,
/// Armenian, Ethiopic).
const _sentenceEnds = '.!?…。！？｡．؟।۔։።';

class _Splitter {
  new(this.text, this.start, this.end, this.maxChars)
    : target = _target(end - start, maxChars) {
    fences = _fences(text);
    cuts = _cuts();
  }

  final String text;
  final int start;
  final int end;
  final int maxChars;

  /// Preferred part length: the text spread evenly over as few parts as the
  /// limit allows.
  final int target;

  late final List<_Span> fences;
  late final List<_Cut> cuts;

  static int _target(int length, int maxChars) {
    final count = (length / maxChars).ceil();
    return (length / count).ceil();
  }

  List<_Span> split() => _split(start, end, _paragraph);

  List<_Span> _split(int from, int to, int level) {
    if (to - from <= maxChars) return [(start: from, end: to)];
    if (level < _word) return _hardSplit(from, to);
    final inner = [
      for (final cut in cuts)
        if (cut.level >= level && cut.start > from && cut.end < to) cut,
    ];
    if (inner.isEmpty) return _split(from, to, level - 1);

    final pieces = <_Span>[];
    var pieceStart = from;
    for (final cut in inner) {
      pieces.add((start: pieceStart, end: cut.start));
      pieceStart = cut.end;
    }
    pieces.add((start: pieceStart, end: to));

    final spans = <_Span>[];
    var current = pieces.first;
    for (final piece in pieces.skip(1)) {
      final length = current.end - current.start;
      if (length < target && piece.end - current.start <= maxChars) {
        current = (start: current.start, end: piece.end);
      } else {
        spans.add(current);
        current = piece;
      }
    }
    spans.add(current);
    return [
      for (final span in spans)
        if (span.end - span.start > maxChars)
          ..._split(span.start, span.end, level - 1)
        else
          span,
    ];
  }

  /// Cuts [from]..[to] (which has no whitespace outside code blocks) every
  /// [maxChars] characters, but never inside a code block or a surrogate
  /// pair.
  List<_Span> _hardSplit(int from, int to) {
    final spans = <_Span>[];
    var position = from;
    while (to - position > maxChars) {
      var cut = position + maxChars;
      final fence = fences.where((f) => f.start < cut && cut < f.end);
      if (fence.isNotEmpty) {
        final block = fence.first;
        cut = block.start > position ? block.start : block.end;
        if (cut >= to) break;
      } else if (_isLowSurrogate(text.codeUnitAt(cut))) {
        // Keep the pair together (after it when the limit is 1).
        cut = cut - 1 > position ? cut - 1 : cut + 1;
      }
      spans.add((start: position, end: cut));
      position = cut;
    }
    if (position < to) spans.add((start: position, end: to));
    return spans;
  }

  List<_Cut> _cuts() {
    final cuts = <_Cut>[];
    for (final match in _whitespace.allMatches(text)) {
      if (match.start <= start || match.end >= end) continue;
      if (_inFence(match.start, match.end)) continue;
      final breaks = _lineBreak.allMatches(match[0]!).length;
      final level = breaks >= 2
          ? _paragraph
          : breaks == 1
          ? _line
          : _endsSentence(match.start)
          ? _sentence
          : _word;
      cuts.add((start: match.start, end: match.end, level: level));
    }
    for (final match in _cjkSentenceEnd.allMatches(text)) {
      final position = match.end;
      if (position <= start || position >= end) continue;
      if (_whitespace.matchAsPrefix(text, position) != null) continue;
      if (_inFence(position, position)) continue;
      cuts.add((start: position, end: position, level: _sentence));
    }
    return cuts..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Whether the whitespace (or empty cut) from [from] to [to] is inside a
  /// code block. Blocks start and end with non-whitespace, so a maximal
  /// whitespace run that overlaps one is inside it.
  bool _inFence(int from, int to) =>
      fences.any((f) => f.start < to && from < f.end);

  bool _endsSentence(int whitespaceStart) {
    var i = whitespaceStart - 1;
    while (i > start && _closers.contains(text[i])) {
      i--;
    }
    return _sentenceEnds.contains(text[i]);
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// Code block ranges: from the opening fence characters to the end of the
  /// closing fence characters (or the end of [text] when unclosed).
  static List<_Span> _fences(String text) {
    final fences = <_Span>[];
    int? blockStart;
    String? marker;
    var lineStart = 0;
    while (true) {
      final newline = text.indexOf('\n', lineStart);
      final lineEnd = newline < 0 ? text.length : newline;
      var line = text.substring(lineStart, lineEnd);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final match = _fenceLine.firstMatch(line);
      if (match != null) {
        final fence = match[1]!;
        final rest = match[2]!;
        // The fence follows at most three spaces.
        final fenceStart = lineStart + line.indexOf(fence);
        if (blockStart == null) {
          // A backtick fence's info string cannot contain backticks.
          if (!(fence.startsWith('`') && rest.contains('`'))) {
            blockStart = fenceStart;
            marker = fence;
          }
        } else if (fence[0] == marker![0] &&
            fence.length >= marker.length &&
            rest.trim().isEmpty) {
          fences.add((start: blockStart, end: fenceStart + fence.length));
          blockStart = null;
        }
      }
      if (newline < 0) break;
      lineStart = newline + 1;
    }
    if (blockStart != null) fences.add((start: blockStart, end: text.length));
    return fences;
  }
}
