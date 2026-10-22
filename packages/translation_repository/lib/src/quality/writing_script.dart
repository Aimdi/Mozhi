import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/language.dart';

/// The writing systems `TranslationQa` tells apart.
enum WritingScript {
  latin,
  cyrillic,
  greek,
  armenian,
  georgian,
  hebrew,
  arabic,
  syriac,
  thaana,
  devanagari,
  bengali,
  gurmukhi,
  gujarati,
  oriya,
  tamil,
  telugu,
  kannada,
  malayalam,
  sinhala,
  thai,
  lao,
  tibetan,
  myanmar,
  khmer,
  ethiopic,
  mongolian,
  hangul,

  /// Hiragana and katakana.
  kana,

  /// Chinese characters (also Japanese kanji and Korean hanja).
  han,

  /// Any other script.
  other;

  /// The script of the letter [rune] (classify letters only: some ranges
  /// also hold digits and punctuation).
  static WritingScript of(int rune) {
    for (final (start, end, script) in _ranges) {
      if (rune < start) break;
      if (rune <= end) return script;
    }
    return other;
  }

  static final _letter = RegExp(r'\p{L}', unicode: true);

  /// How many letters of each script [text] has.
  static Map<WritingScript, int> count(String text) {
    final counts = <WritingScript, int>{};
    for (final match in _letter.allMatches(text)) {
      final script = of(match.group(0)!.runes.first);
      counts[script] = (counts[script] ?? 0) + 1;
    }
    return counts;
  }

  /// The script most letters of [text] are in, or null without letters.
  static WritingScript? dominant(String text) {
    WritingScript? best;
    var most = 0;
    for (final MapEntry(key: script, value: letters) in count(text).entries) {
      if (letters > most) {
        best = script;
        most = letters;
      }
    }
    return best;
  }

  /// The scripts text in [language] is written in, or null when unknown
  /// (custom languages, auto, codes without a catalogue entry). An explicit
  /// script subtag decides (`sr-Latn`, `zh-Hant`); Japanese is kana and
  /// kanji, Korean Hangul (and hanja), Chinese Han; otherwise the script of
  /// the catalogue's native name.
  static Set<WritingScript>? expectedFor(Language language) {
    if (language.isCustom || language.isAuto) return null;
    final code = LanguageMatcher.normalize(language.code);
    final primary = code.split('-').first.toLowerCase();
    // The script subtag as written (normalising may drop it).
    for (final part
        in language.code.trim().replaceAll('_', '-').split('-').skip(1)) {
      if (part.length != 4) continue;
      final byTag = _scriptTags[part.toLowerCase()];
      if (byTag != null) return byTag;
    }
    switch (primary) {
      case 'ja':
        return const {kana, han};
      case 'ko':
        return const {hangul, han};
      case 'zh' || 'yue' || 'wuu' || 'lzh' || 'cmn':
        return const {han};
    }
    final native =
        (LanguageCatalog.byCode(code) ?? LanguageCatalog.byCode(primary))
            ?.nativeName;
    if (native == null) return null;
    final script = dominant(native);
    return script == null || script == other ? null : {script};
  }

  static const _scriptTags = <String, Set<WritingScript>>{
    'latn': {latin},
    'cyrl': {cyrillic},
    'grek': {greek},
    'arab': {arabic},
    'hebr': {hebrew},
    'deva': {devanagari},
    'beng': {bengali},
    'guru': {gurmukhi},
    'hans': {han},
    'hant': {han},
    'hani': {han},
    'jpan': {kana, han},
    'kore': {hangul, han},
    'thaa': {thaana},
    'tibt': {tibetan},
    'mong': {mongolian},
    'syrc': {syriac},
  };

  /// Sorted, non-overlapping ranges of letters by script.
  static const List<(int, int, WritingScript)> _ranges = [
    (0x0041, 0x005A, latin),
    (0x0061, 0x007A, latin),
    (0x00AA, 0x00AA, latin),
    (0x00BA, 0x00BA, latin),
    (0x00C0, 0x02AF, latin),
    (0x0370, 0x03FF, greek),
    (0x0400, 0x052F, cyrillic),
    (0x0530, 0x058F, armenian),
    (0x0590, 0x05FF, hebrew),
    (0x0600, 0x06FF, arabic),
    (0x0700, 0x074F, syriac),
    (0x0750, 0x077F, arabic),
    (0x0780, 0x07BF, thaana),
    (0x08A0, 0x08FF, arabic),
    (0x0900, 0x097F, devanagari),
    (0x0980, 0x09FF, bengali),
    (0x0A00, 0x0A7F, gurmukhi),
    (0x0A80, 0x0AFF, gujarati),
    (0x0B00, 0x0B7F, oriya),
    (0x0B80, 0x0BFF, tamil),
    (0x0C00, 0x0C7F, telugu),
    (0x0C80, 0x0CFF, kannada),
    (0x0D00, 0x0D7F, malayalam),
    (0x0D80, 0x0DFF, sinhala),
    (0x0E00, 0x0E7F, thai),
    (0x0E80, 0x0EFF, lao),
    (0x0F00, 0x0FFF, tibetan),
    (0x1000, 0x109F, myanmar),
    (0x10A0, 0x10FF, georgian),
    (0x1100, 0x11FF, hangul),
    (0x1200, 0x139F, ethiopic),
    (0x1780, 0x17FF, khmer),
    (0x1800, 0x18AF, mongolian),
    (0x1C80, 0x1C8F, cyrillic),
    (0x1C90, 0x1CBF, georgian),
    (0x1E00, 0x1EFF, latin),
    (0x1F00, 0x1FFF, greek),
    (0x2C60, 0x2C7F, latin),
    (0x2D00, 0x2D2F, georgian),
    (0x2DE0, 0x2DFF, cyrillic),
    (0x3005, 0x3007, han),
    (0x3021, 0x3029, han),
    (0x3031, 0x3035, kana),
    (0x3040, 0x30FF, kana),
    (0x3130, 0x318F, hangul),
    (0x31F0, 0x31FF, kana),
    (0x3400, 0x4DBF, han),
    (0x4E00, 0x9FFF, han),
    (0xA640, 0xA69F, cyrillic),
    (0xA720, 0xA7FF, latin),
    (0xAB30, 0xAB6F, latin),
    (0xAC00, 0xD7AF, hangul),
    (0xF900, 0xFAFF, han),
    (0xFB00, 0xFB06, latin),
    (0xFB1D, 0xFB4F, hebrew),
    (0xFB50, 0xFDFF, arabic),
    (0xFE70, 0xFEFF, arabic),
    (0xFF21, 0xFF3A, latin),
    (0xFF41, 0xFF5A, latin),
    (0xFF66, 0xFF9F, kana),
    (0xFFA0, 0xFFDC, hangul),
    (0x20000, 0x323AF, han),
  ];
}
