/// Splits long text into pieces the engine translates one after another, so
/// one request never blocks the translation isolate for long and memory
/// stays bounded.
///
/// Pieces end at paragraph breaks (blank lines), then line breaks, then
/// sentence ends, and only as a last resort at a space; the separators are
/// kept in the pieces, so joining the translated pieces restores the
/// layout. The engine itself still splits each piece into sentences.
abstract final class TextChunker {
  /// Splits [text] into pieces of at most [maxLength] UTF-16 code units
  /// (longer only when a single word is longer). Concatenating the result
  /// gives [text] back.
  static List<String> split(String text, {int maxLength = 2000}) {
    if (maxLength < 1) {
      throw ArgumentError.value(maxLength, 'maxLength', 'Must be positive');
    }
    if (text.length <= maxLength) return [text];
    final pieces = <String>[];
    var start = 0;
    while (text.length - start > maxLength) {
      final end = _breakBefore(text, start, start + maxLength);
      pieces.add(text.substring(start, end));
      start = end;
    }
    if (start < text.length) pieces.add(text.substring(start));
    return pieces;
  }

  /// The best break in `text[start, limit)`: an index after a separator, so
  /// separators stay with the preceding piece.
  static int _breakBefore(String text, int start, int limit) {
    final window = text.substring(start, limit);
    for (final pattern in _breaks) {
      final matches = pattern.allMatches(window).toList();
      if (matches.isNotEmpty && matches.last.end > 0) {
        return start + matches.last.end;
      }
    }
    // One very long word: break it at the limit, never inside a surrogate
    // pair.
    final end = limit;
    final unit = text.codeUnitAt(end - 1);
    return (unit >= 0xD800 && unit <= 0xDBFF) ? end - 1 : end;
  }

  static final _breaks = [
    RegExp(r'\n[ \t]*\n\s*'),
    RegExp(r'\n\s*'),
    // Sentence ends: Latin/Cyrillic/Greek punctuation + space, CJK and
    // Devanagari/Thai/Arabic full stops.
    RegExp(r'[.!?;…»"”)\]]+\s+|[。！？；]+\s*|[।॥؟۔]+\s*'),
    RegExp(r'\s+'),
  ];
}
