/// Turns a word into the key a dictionary pack indexes it under: each code
/// point mapped through the pack's fold table (case and accent folding),
/// then runs of spaces collapsed to one space and the ends trimmed.
///
/// The builder writes the table into the pack for every character its
/// headwords and inflected forms use (and their other cases), so a reader
/// folds a query exactly as the builder folded the words, without
/// Unicode tables of its own: `Café` and `cafe` both find `café`.
/// Characters without a mapping stay as they are.
final class DictionaryKeyFolder {
  /// [table] maps one code point (a one-character string) to its folded
  /// text (empty to drop it).
  new(Map<String, String> table)
    : _table = {
        for (final MapEntry(:key, :value) in table.entries)
          if (key.runes.length == 1) key.runes.single: value,
      };

  final Map<int, String> _table;

  /// Space characters that separate words in a key.
  static final spaces = RegExp(
    '[\t\n\x0b\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000'
    '\ufeff]+',
  );

  /// The fold table (code point to folded text).
  Map<int, String> get table => Map.unmodifiable(_table);

  /// The key of [text].
  String fold(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final mapped = _table[rune];
      if (mapped != null) {
        buffer.write(mapped);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return collapseSpaces(buffer.toString());
  }

  /// [text] with each run of [spaces] made one space and no space at
  /// either end.
  static String collapseSpaces(String text) {
    final collapsed = text.replaceAll(spaces, ' ');
    var start = 0;
    var end = collapsed.length;
    while (start < end && collapsed.codeUnitAt(start) == 0x20) {
      start++;
    }
    while (end > start && collapsed.codeUnitAt(end - 1) == 0x20) {
      end--;
    }
    return collapsed.substring(start, end);
  }
}

/// The folding of one code point used by `DictionaryPackWriter` (packs
/// built in Dart, e.g. in tests): curly apostrophes become `'`, combining
/// diacritics (U+0300 to U+036F) are dropped, then the character is lower
/// cased and a Latin letter with a diacritic becomes its base letter.
///
/// The pack builder (`tool/dictionary_packs.py`) folds with Unicode's full
/// case folding and canonical decomposition instead; either way the pack
/// carries its own table, so readers never depend on this function.
String basicFoldRune(int rune) {
  if (rune == 0x2018 || rune == 0x2019 || rune == 0x02bc) return "'";
  if (rune >= 0x300 && rune <= 0x36f) return '';
  final lower = String.fromCharCode(rune).toLowerCase();
  final buffer = StringBuffer();
  for (final char in lower.runes) {
    buffer.write(_latinBase[char] ?? String.fromCharCode(char));
  }
  return buffer.toString();
}

/// Lower-case Latin letters with a canonical decomposition, by base letter.
const _latinLetters = {
  'a': 'àáâãäåāăąǎǟǡǻȁȃȧạảấầẩẫậắằẳẵặ',
  'c': 'çćĉċč',
  'd': 'ď',
  'e': 'èéêëēĕėęěȅȇȩẹẻẽếềểễệ',
  'g': 'ĝğġģǧǵ',
  'h': 'ĥ',
  'i': 'ìíîïĩīĭįǐȉȋỉị',
  'j': 'ĵǰ',
  'k': 'ķǩ',
  'l': 'ĺļľ',
  'n': 'ñńņňǹ',
  'o': 'òóôõöōŏőǒǫǭȍȏȫȭȯȱọỏốồổỗộớờởỡợơ',
  'r': 'ŕŗřȑȓ',
  's': 'śŝşšș',
  't': 'ţťț',
  'u': 'ùúûüũūŭůűųǔǖǘǚǜȕȗụủứừửữựư',
  'w': 'ŵẁẃẅ',
  'y': 'ýÿŷȳỳỵỷỹ',
  'z': 'źżž',
};

final Map<int, String> _latinBase = {
  for (final MapEntry(key: base, value: letters) in _latinLetters.entries)
    for (final letter in letters.runes) letter: base,
};
