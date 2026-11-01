import 'package:translation_repository/translation_repository.dart';

/// Lower-case letters with diacritics (Latin, Greek and Cyrillic) and, at
/// the same index in [_plain], the letter without them.
const _accented =
    'àáâãäåçèéêëìíîïñòóôõöùúûüýÿāăą'
    'ćĉċčďēĕėęěĝğġģĥĩīĭįĵķĺļľńņňōŏő'
    'ŕŗřśŝşšţťũūŭůűųŵŷźżžơưǎǐǒǔǖǘǚǜ'
    'ǟǡǣǧǩǫǭǯǰǵǹǻǽǿȁȃȅȇȉȋȍȏȑȓȕȗșțȟȧ'
    'ȩȫȭȯȱȳḁḃḅḇḉḋḍḏḑḓḕḗḙḛḝḟḡḣḥḧḩḫḭḯ'
    'ḱḳḵḷḹḻḽḿṁṃṅṇṉṋṍṏṑṓṕṗṙṛṝṟṡṣṥṧṩṫ'
    'ṭṯṱṳṵṷṹṻṽṿẁẃẅẇẉẋẍẏẑẓẕẖẗẘẙẛạảấầ'
    'ẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợ'
    'ụủứừửữựỳỵỷỹΐάέήίΰϊϋόύώйѐёѓїќѝў'
    'ѷӂӑӓӗӛӝӟӣӥӧӫӭӯӱӳӵӹ';

const _plain =
    'aaaaaaceeeeiiiinooooouuuuyyaaa'
    'ccccdeeeeegggghiiiijklllnnnooo'
    'rrrssssttuuuuuuwyzzzouaiouuuuu'
    'aaægkooʒjgnaæøaaeeiioorruustha'
    'eooooyabbbcdddddeeeeefghhhhhii'
    'kkkllllmmmnnnnoooopprrrrssssst'
    'tttuuuuuvvwwwwwxxyzzzhtwyſaaaa'
    'aaaaaaaaeeeeeeeeiioooooooooooo'
    'uuuuuuuyyyyιαεηιυιυουωиеегікиу'
    'ѵжааеәжзииоөэууучы';

/// Letters spelled with others when searching ("ß" as "ss").
const _spelledOut = <int, String>{
  0x00DF: 'ss', // ß
  0x00E6: 'ae', // æ
  0x00F0: 'd', // ð
  0x00F8: 'o', // ø
  0x00FE: 'th', // þ
  0x0111: 'd', // đ
  0x0127: 'h', // ħ
  0x0131: 'i', // ı
  0x0140: 'l', // ŀ
  0x0142: 'l', // ł
  0x0153: 'oe', // œ
  0x0167: 't', // ŧ
  0x017F: 's', // ſ
  0x0292: 'z', // ʒ
  0x03C2: 'σ', // final sigma
};

final Map<int, int> _folds = () {
  final from = _accented.runes.toList();
  final to = _plain.runes.toList();
  assert(from.length == to.length, 'diacritic table out of step');
  return {for (var i = 0; i < from.length; i++) from[i]: to[i]};
}();

/// Whether [rune] is a combining mark (accents typed or stored separately).
bool _isCombining(int rune) =>
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF);

/// [text] for diacritic-insensitive search (and sorting): lower case,
/// accents removed ("Français" → "francais", "Tiếng Việt" → "tieng viet",
/// "Ελληνικά" → "ελληνικα") and a few letters spelled out ("Bokmål" →
/// "bokmal", "Føroyskt" → "foroyskt", "ß" → "ss"). Other scripts are kept
/// as they are.
String foldForSearch(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    if (_isCombining(rune)) continue;
    final folded = _folds[rune] ?? rune;
    final spelled = _spelledOut[folded];
    if (spelled != null) {
      buffer.write(spelled);
    } else {
      buffer.writeCharCode(folded);
    }
  }
  return buffer.toString();
}

/// The languages of [languages] that match [query], best first: those
/// whose English or native name, or name in the UI language
/// ([displayName], e.g. `context.languageName`: "Französisch"), or a word
/// in one of them, starts with the query or whose code is the query, then
/// those whose name contains it. Matching ignores case and diacritics
/// ([foldForSearch]): "francais" finds French (Français), "espanol"
/// Spanish (Español), "franzosisch" French in German. "Detect language" is
/// never a match.
List<Language> matchLanguages(
  Iterable<Language> languages,
  String query, {
  String Function(Language language)? displayName,
}) {
  final q = foldForSearch(query.trim());
  if (q.isEmpty) return const [];
  final starts = <Language>[];
  final words = <Language>[];
  final contains = <Language>[];
  for (final language in languages) {
    if (language.isAuto) continue;
    final names = [
      foldForSearch(language.name),
      if (language.nativeName case final native? when native.isNotEmpty)
        foldForSearch(native),
      if (displayName?.call(language) case final shown?
          when shown != language.name)
        foldForSearch(shown),
    ];
    final code = language.code.toLowerCase();
    if (code == q || names.any((name) => name.startsWith(q))) {
      starts.add(language);
    } else if (names.any((name) => _wordStartsWith(name, q))) {
      words.add(language);
    } else if (names.any((name) => name.contains(q))) {
      contains.add(language);
    }
  }
  return [...starts, ...words, ...contains];
}

/// [languages] in the order of the names they are shown with
/// ([displayName], e.g. `context.languageName`), ignoring case and
/// diacritics ([foldForSearch]): "Ägyptisch" next to "Afrikaans". Equal
/// names keep their order. When no language is shown with a name other
/// than its [Language.name] (an English UI), the order is kept as given.
List<Language> sortLanguagesByName(
  Iterable<Language> languages,
  String Function(Language language) displayName,
) {
  final named = [
    for (final language in languages) (language, displayName(language)),
  ];
  if (named.every((entry) => entry.$2 == entry.$1.name)) {
    return [for (final (language, _) in named) language];
  }
  final keyed =
      [
        for (final (index, (language, name)) in named.indexed)
          (language: language, key: foldForSearch(name), index: index),
      ]..sort((a, b) {
        final byName = a.key.compareTo(b.key);
        return byName != 0 ? byName : a.index.compareTo(b.index);
      });
  return [for (final entry in keyed) entry.language];
}

/// Whether a word of [name] after the first starts with [query] ("Chinese
/// (Simplified)" for "simp").
bool _wordStartsWith(String name, String query) {
  for (final match in _wordStart.allMatches(name)) {
    if (name.startsWith(query, match.end)) return true;
  }
  return false;
}

final _wordStart = RegExp(r'[\s(\-/,]+');
