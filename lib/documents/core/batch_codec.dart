/// How several texts travel in one translation request and are split back.
enum ChunkEncoding {
  /// One text, sent as is.
  single,

  /// Texts separated by blank lines (prose: paragraphs, headings, list
  /// items). Only usable when no text contains a blank line itself.
  paragraphs,

  /// Every text prefixed by a numbered marker line (`⟦1⟧ text`) — used for
  /// subtitle cues and string tables, where texts are short and
  /// alignment matters.
  markers,
}

/// Encodes/decodes batches for [ChunkEncoding.paragraphs] and
/// [ChunkEncoding.markers].
abstract final class BatchCodec {
  static const markerOpen = '⟦';
  static const markerClose = '⟧';

  static String marker(int number) => '$markerOpen$number$markerClose';

  /// `⟦n⟧`, also tolerating spaces and `[[n]]` (some engines normalise
  /// unusual brackets).
  static final markerPattern = RegExp(r'(?:⟦|\[\[)\s*(\d{1,4})\s*(?:⟧|\]\])');

  static final _blankLine = RegExp(r'\n[ \t]*\n');

  /// Whether [text] contains a blank line (so it cannot be batched as
  /// paragraphs).
  static bool hasBlankLine(String text) =>
      _blankLine.hasMatch(text.replaceAll('\r\n', '\n'));

  /// Joins [texts] for [encoding].
  static String encode(List<String> texts, ChunkEncoding encoding) =>
      switch (encoding) {
        ChunkEncoding.single => texts.single,
        ChunkEncoding.paragraphs => texts.join('\n\n'),
        ChunkEncoding.markers => [
          for (var i = 0; i < texts.length; i++) '${marker(i + 1)} ${texts[i]}',
        ].join('\n'),
      };

  /// Splits a translated batch back into [count] texts, or returns null
  /// when the alignment was lost (missing, duplicated or reordered
  /// markers; a different number of paragraphs; an empty piece).
  static List<String>? decode(
    String output,
    int count,
    ChunkEncoding encoding,
  ) {
    final text = output.replaceAll('\r\n', '\n').trim();
    final List<String> pieces;
    switch (encoding) {
      case ChunkEncoding.single:
        pieces = [text];
      case ChunkEncoding.paragraphs:
        pieces = text.isEmpty
            ? const []
            : [for (final piece in text.split(_paragraphBreak)) piece.trim()];
      case ChunkEncoding.markers:
        final matches = markerPattern.allMatches(text).toList();
        if (matches.length != count) return null;
        pieces = [];
        for (var i = 0; i < matches.length; i++) {
          if (int.parse(matches[i].group(1)!) != i + 1) return null;
          final end = i + 1 < matches.length
              ? matches[i + 1].start
              : text.length;
          pieces.add(text.substring(matches[i].end, end).trim());
        }
    }
    if (pieces.length != count || pieces.any((piece) => piece.isEmpty)) {
      return null;
    }
    return pieces;
  }

  static final _paragraphBreak = RegExp(r'\n[ \t]*\n\s*');
}
