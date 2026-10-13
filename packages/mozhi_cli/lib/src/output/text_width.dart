/// Number of terminal columns [text] occupies: East Asian wide and
/// full-width characters and most emoji count as two, combining marks and
/// zero-width characters as zero. ANSI escape sequences are ignored.
int displayWidth(String text) {
  var width = 0;
  for (final rune in stripAnsi(text).runes) {
    width += runeWidth(rune);
  }
  return width;
}

final _ansiPattern = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

/// [text] without ANSI escape sequences.
String stripAnsi(String text) => text.replaceAll(_ansiPattern, '');

/// Width of a single code point (see [displayWidth]).
int runeWidth(int rune) {
  if (rune == 0 || rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) return 0;
  if (_isZeroWidth(rune)) return 0;
  return _isWide(rune) ? 2 : 1;
}

bool _isZeroWidth(int r) =>
    (r >= 0x0300 && r <= 0x036f) || // combining diacritics
    (r >= 0x0483 && r <= 0x0489) ||
    (r >= 0x0591 && r <= 0x05bd) ||
    (r >= 0x0610 && r <= 0x061a) ||
    (r >= 0x064b && r <= 0x065f) ||
    (r >= 0x0900 && r <= 0x0903) || // Devanagari signs
    (r >= 0x093a && r <= 0x094f && r != 0x093d) ||
    (r >= 0x0e31 && r <= 0x0e3a && r != 0x0e32 && r != 0x0e33) || // Thai
    (r >= 0x0e47 && r <= 0x0e4e) ||
    (r >= 0x1ab0 && r <= 0x1aff) ||
    (r >= 0x1dc0 && r <= 0x1dff) ||
    (r >= 0x200b && r <= 0x200f) || // zero-width space/joiners, marks
    (r >= 0x20d0 && r <= 0x20ff) ||
    (r >= 0xfe00 && r <= 0xfe0f) || // variation selectors
    (r >= 0xfe20 && r <= 0xfe2f) ||
    r == 0xfeff ||
    (r >= 0xe0100 && r <= 0xe01ef);

bool _isWide(int r) =>
    (r >= 0x1100 && r <= 0x115f) || // Hangul Jamo
    (r >= 0x2e80 && r <= 0x303e) || // CJK radicals, punctuation
    (r >= 0x3041 && r <= 0x33ff) || // Kana, CJK symbols
    (r >= 0x3400 && r <= 0x4dbf) || // CJK extension A
    (r >= 0x4e00 && r <= 0x9fff) || // CJK unified ideographs
    (r >= 0xa000 && r <= 0xa4cf) || // Yi
    (r >= 0xac00 && r <= 0xd7a3) || // Hangul syllables
    (r >= 0xf900 && r <= 0xfaff) || // CJK compatibility
    (r >= 0xfe30 && r <= 0xfe4f) ||
    (r >= 0xff00 && r <= 0xff60) || // full-width forms
    (r >= 0xffe0 && r <= 0xffe6) ||
    (r >= 0x1f300 && r <= 0x1f64f) || // emoji
    (r >= 0x1f900 && r <= 0x1f9ff) ||
    (r >= 0x1fa70 && r <= 0x1faff) ||
    (r >= 0x20000 && r <= 0x3fffd); // CJK extensions B+

/// Pads [text] with spaces to [width] display columns.
String padDisplay(String text, int width) {
  final missing = width - displayWidth(text);
  return missing > 0 ? '$text${' ' * missing}' : text;
}
