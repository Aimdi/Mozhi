import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/models/language.dart';

/// Maps a language code onto the closest entry of another engine's list
/// so the user's selection survives engine switches.
///
/// Rules (first match wins): exact code (case-insensitive, `_`==`-`);
/// known aliases (`nb`<->`no`, `he`<->`iw`, `jv`<->`jw`, `fil`<->`tl`,
/// `zh`/`zh-Hans`/`zh-CN`/`zh-SG`, `zh-Hant`/`zh-TW`/`zh-HK`, `pt`/`pt-BR`/
/// `pt-PT`, `sr`/`sr-Cyrl`, `ku`/`kmr`, `mni-Mtei`/`mni`, `ckb`/`ku-IQ`);
/// same primary subtag (`en-GB` -> `en`, `en` -> first `en-*`);
/// finally case-insensitive English name equality.
/// Custom languages only match custom entries or are returned as-is when
/// [allowCustom] is true.
abstract final class LanguageMatcher {
  static Language? match(
    Language wanted,
    List<Language> available, {
    bool allowCustom = false,
  }) {
    if (wanted.isCustom) {
      final key = wanted.code.trim().toLowerCase();
      for (final language in available) {
        if (language.isCustom && language.code.trim().toLowerCase() == key) {
          return language;
        }
      }
      return allowCustom ? wanted : null;
    }

    final candidates = [
      for (final language in available)
        if (!language.isCustom) language,
    ];
    if (candidates.isEmpty) return null;
    final wantedKey = _key(wanted.code);

    // 1. Exact code.
    for (final language in candidates) {
      if (_key(language.code) == wantedKey) return language;
    }

    // 2. Known aliases (in priority order), then codes that normalise to the
    // same catalogue code (`he-IL` ~ `iw`, `zh-Hans-CN` ~ `zh-CN`).
    for (final alias in _aliasesOf(wantedKey)) {
      for (final language in candidates) {
        if (_key(language.code) == alias) return language;
      }
    }
    final wantedNormalized = normalize(wanted.code);
    if (wantedNormalized.isNotEmpty) {
      for (final language in candidates) {
        if (normalize(language.code) == wantedNormalized) return language;
      }
    }

    // 3. Same primary subtag: the bare primary code first, then the first
    // regional/script variant.
    final primary = _primary(wantedNormalized);
    if (primary.isNotEmpty) {
      for (final language in candidates) {
        if (_key(language.code) == primary) return language;
      }
      for (final language in candidates) {
        if (_primary(normalize(language.code)) == primary) return language;
      }
    }

    // 4. English name.
    final name = wanted.name.trim().toLowerCase();
    if (name.isNotEmpty) {
      for (final language in candidates) {
        if (language.name.trim().toLowerCase() == name) return language;
      }
      final loose = _looseName(name);
      if (loose.isNotEmpty) {
        for (final language in candidates) {
          if (_looseName(language.name) == loose) return language;
        }
      }
    }
    return null;
  }

  /// Normalises engine-specific codes to catalogue codes
  /// (e.g. `iw` -> `he`, `zh-CN` -> `zh-CN`, `ZH_tw` -> `zh-TW`).
  ///
  /// Casing follows BCP-47 conventions (`sr-latn` -> `sr-Latn`), legacy and
  /// ISO 639-2/3 codes map to their catalogue equivalent (`jw` -> `jv`,
  /// `nb` -> `no`, `fil` -> `tl`, `deu` -> `de`, `zh-Hant` -> `zh-TW`), and
  /// unknown regional variants fall back to a catalogued parent
  /// (`fr-FR` -> `fr`, `sr-Latn-RS` -> `sr-Latn`). Codes that cannot be
  /// related to the catalogue are returned in canonical casing.
  static String normalize(String code) {
    final canonical = _canonicalCase(code);
    if (canonical.isEmpty) return canonical;
    final parts = canonical.split('-');
    for (var length = parts.length; length >= 1; length--) {
      final candidate = parts.take(length).join('-');
      final lower = candidate.toLowerCase();
      final alias = _normalizeAliases[lower];
      if (alias != null) return alias;
      final known = _catalogCodes[lower];
      if (known != null) return known;
    }
    return canonical;
  }

  static final Map<String, String> _catalogCodes = {
    for (final language in LanguageCatalog.all)
      language.code.toLowerCase(): language.code,
  };

  /// Alias groups from the class doc, most preferred first.
  static const _aliasGroups = <List<String>>[
    ['no', 'nb'],
    ['he', 'iw'],
    ['jv', 'jw'],
    ['tl', 'fil'],
    ['id', 'in'],
    ['yi', 'ji'],
    ['zh-cn', 'zh', 'zh-hans', 'zh-sg', 'zh-hans-cn'],
    ['zh-tw', 'zh-hant', 'zh-hk', 'zh-mo', 'zh-hant-tw'],
    ['pt', 'pt-br', 'pt-pt'],
    ['sr', 'sr-cyrl'],
    ['ku', 'kmr', 'ku-latn'],
    ['mni-mtei', 'mni'],
    ['ckb', 'ku-iq', 'ku-arab'],
    ['ak', 'tw'],
    ['fa-af', 'prs'],
    ['gom', 'kok'],
    ['yue', 'zh-yue'],
  ];

  static Iterable<String> _aliasesOf(String key) sync* {
    for (final group in _aliasGroups) {
      if (group.contains(key)) yield* group.where((c) => c != key);
    }
  }

  /// Lower-case code -> catalogue code.
  static const _normalizeAliases = <String, String>{
    // Legacy / engine-specific ISO 639-1 codes.
    'iw': 'he',
    'jw': 'jv',
    'in': 'id',
    'ji': 'yi',
    'mo': 'ro',
    'tw': 'ak',
    'fil': 'tl',
    'nb': 'no',
    'mni': 'mni-Mtei',
    'kmr': 'ku',
    'ku-latn': 'ku',
    'ku-iq': 'ckb',
    'ku-arab': 'ckb',
    'sr-cyrl': 'sr',
    'prs': 'fa-AF',
    'kok': 'gom',
    'zh': 'zh-CN',
    'zh-hans': 'zh-CN',
    'zh-sg': 'zh-CN',
    'zh-my': 'zh-CN',
    'zh-hant': 'zh-TW',
    'zh-hk': 'zh-TW',
    'zh-mo': 'zh-TW',
    'zh-yue': 'yue',
    'cmn': 'zh-CN',
    'cmn-hans': 'zh-CN',
    'cmn-hant': 'zh-TW',
    'pa-guru': 'pa',
    'pa-pk': 'pa-Arab',
    'ms-jawi': 'ms-Arab',
    'sat-olck': 'sat',
    'ber-tfng': 'ber',
    'zgh': 'ber',
    'tzm': 'ber-Latn',
    // Arabic varieties (ISO 639-3).
    'arb': 'ar',
    'arz': 'ar-EG',
    'ary': 'ar-MA',
    'arq': 'ar-DZ',
    'aeb': 'ar-TN',
    'apc': 'ar-LB',
    'ajp': 'ar-LB',
    'afb': 'ar-AE',
    'acm': 'ar-IQ',
    'apd': 'ar-SD',
    // Individual languages of macrolanguages / ISO 639-3 variants.
    'pes': 'fa',
    'zsm': 'ms',
    'nob': 'no',
    'nno': 'nn',
    'swh': 'sw',
    'ekk': 'et',
    'lvs': 'lv',
    'khk': 'mn',
    'uzn': 'uz',
    'azj': 'az',
    'pbu': 'ps',
    'npi': 'ne',
    'ory': 'or',
    'gug': 'gn',
    'quy': 'qu',
    'ydd': 'yi',
    'plt': 'mg',
    'tgl': 'tl',
    // Common ISO 639-2 (T and B) codes.
    'eng': 'en',
    'fra': 'fr',
    'fre': 'fr',
    'deu': 'de',
    'ger': 'de',
    'spa': 'es',
    'ita': 'it',
    'por': 'pt',
    'rus': 'ru',
    'jpn': 'ja',
    'kor': 'ko',
    'zho': 'zh-CN',
    'chi': 'zh-CN',
    'ara': 'ar',
    'hin': 'hi',
    'nld': 'nl',
    'dut': 'nl',
    'pol': 'pl',
    'tur': 'tr',
    'ukr': 'uk',
    'vie': 'vi',
    'tha': 'th',
    'ind': 'id',
    'swe': 'sv',
    'ces': 'cs',
    'cze': 'cs',
    'ell': 'el',
    'gre': 'el',
    'heb': 'he',
    'fas': 'fa',
    'per': 'fa',
  };

  static String _key(String code) =>
      code.trim().replaceAll('_', '-').toLowerCase();

  static String _primary(String code) => _key(code).split('-').first;

  static String _looseName(String name) => name.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );

  /// `ZH_hant_tw` -> `zh-Hant-TW`.
  static String _canonicalCase(String code) {
    final parts = code
        .trim()
        .split(RegExp('[-_]'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    final out = <String>[parts.first.toLowerCase()];
    for (final part in parts.skip(1)) {
      final isAlpha = RegExp(r'^[A-Za-z]+$').hasMatch(part);
      if (isAlpha && part.length == 4) {
        out.add(part[0].toUpperCase() + part.substring(1).toLowerCase());
      } else if (isAlpha && part.length == 2) {
        out.add(part.toUpperCase());
      } else {
        out.add(part.toLowerCase());
      }
    }
    return out.join('-');
  }
}
