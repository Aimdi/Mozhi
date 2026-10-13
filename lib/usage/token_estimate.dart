/// Rough token estimates for AI providers, for showing "≈ N tokens" and for
/// usage tracking.
///
/// Heuristic: about 4 characters per token for alphabetic scripts, and about
/// 1 token per CJK character (Chinese, Japanese and Korean scripts tokenize
/// far less efficiently). Real tokenizers differ per provider and model, so
/// treat the result as an order of magnitude, not a bill.
library;

/// Characters per token for non-CJK text.
const charsPerToken = 4;

/// Breakdown of a text for [estimateTokens].
class TokenEstimate {
  const new({this.characters = 0, this.cjkCharacters = 0})
    : assert(cjkCharacters <= characters, 'more CJK than total characters');

  /// Measures [text] by Unicode code points.
  factory of(String text) {
    var characters = 0;
    var cjk = 0;
    for (final rune in text.runes) {
      characters++;
      if (isCjkRune(rune)) cjk++;
    }
    return TokenEstimate(characters: characters, cjkCharacters: cjk);
  }

  /// Unicode code points in the text.
  final int characters;

  /// Code points counted as one token each.
  final int cjkCharacters;

  /// Estimated tokens: one per CJK character plus a quarter (rounded up) of
  /// the other characters.
  int get tokens =>
      cjkCharacters + estimateTokensForChars(characters - cjkCharacters);
}

/// Estimated tokens of [text]; see [TokenEstimate].
int estimateTokens(String text) => TokenEstimate.of(text).tokens;

/// Estimated tokens of [chars] non-CJK characters (`chars / 4`, rounded up).
int estimateTokensForChars(int chars) =>
    chars <= 0 ? 0 : (chars + charsPerToken - 1) ~/ charsPerToken;

/// Whether [rune] belongs to a Chinese, Japanese or Korean script block
/// (ideographs, kana, hangul, bopomofo, CJK punctuation and full-width
/// forms).
bool isCjkRune(int rune) =>
    (rune >= 0x1100 && rune <= 0x11FF) || // Hangul Jamo
    (rune >= 0x2E80 && rune <= 0x2FDF) || // CJK & Kangxi radicals
    (rune >= 0x2FF0 && rune <= 0x303F) || // Ideographic description, punct.
    (rune >= 0x3040 && rune <= 0x31FF) || // Kana, Bopomofo, compat. Jamo …
    (rune >= 0x3200 && rune <= 0x4DBF) || // Enclosed, compat., Ext. A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // Unified ideographs
    (rune >= 0xA960 && rune <= 0xA97F) || // Hangul Jamo Ext. A
    (rune >= 0xAC00 && rune <= 0xD7FF) || // Hangul syllables, Jamo Ext. B
    (rune >= 0xF900 && rune <= 0xFAFF) || // Compatibility ideographs
    (rune >= 0xFE30 && rune <= 0xFE4F) || // CJK compatibility forms
    (rune >= 0xFF00 && rune <= 0xFFEF) || // Half-/full-width forms
    (rune >= 0x20000 && rune <= 0x3FFFF); // Supplementary ideographic planes
