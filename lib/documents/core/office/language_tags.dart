/// Which group of script settings an office document uses for a language:
/// Word, PowerPoint and LibreOffice keep separate language settings for
/// Western, East Asian and complex (right-to-left and Indic) scripts.
enum ScriptClass { western, asian, complex }

/// A target language as office documents and e-books record it.
final class LanguageTag {
  const new _(this.language, this.script, this.region);

  /// Parses a BCP 47 code (`de`, `pt-BR`, `zh-Hant-TW`, `sr_Latn`); null
  /// for anything that is not one (custom AI "languages").
  static LanguageTag? tryParse(String? code) {
    if (code == null) return null;
    final parts = code.trim().replaceAll('_', '-').split('-');
    if (parts.isEmpty || !_languagePattern.hasMatch(parts.first)) return null;
    var language = parts.first.toLowerCase();
    language = _legacy[language] ?? language;
    String? script;
    String? region;
    for (final part in parts.skip(1)) {
      if (script == null && region == null && _scriptPattern.hasMatch(part)) {
        script = '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
      } else if (region == null && _regionPattern.hasMatch(part)) {
        region = part.toUpperCase();
      } else {
        // Variants and extensions are not written to office files.
        break;
      }
    }
    return LanguageTag._(language, script, region);
  }

  /// ISO 639 language subtag (`de`).
  final String language;

  /// ISO 15924 script subtag (`Hant`), if given.
  final String? script;

  /// Region subtag (`BR`), if given.
  final String? region;

  /// The region written to office files: the given one, or the most common
  /// one for the language (`de` -> `DE`), or null when unknown.
  String? get officeRegion =>
      region ?? (script == null ? _defaultRegions[language] : null);

  /// The tag as written in an e-book or XHTML document (`pt-BR`).
  String get bcp47 => [language, ?script, ?region].join('-');

  /// The culture name Office writes (`de-DE`, `zh-CN`, `sr-Latn-RS`).
  String get culture => [language, ?script, ?officeRegion].join('-');

  /// The settings group of the language's script.
  ScriptClass get scriptClass {
    if (_asian.contains(language)) return ScriptClass.asian;
    if (_complex.contains(language)) return ScriptClass.complex;
    if (script == 'Arab' || script == 'Hebr') return ScriptClass.complex;
    return ScriptClass.western;
  }

  @override
  String toString() => 'LanguageTag($bcp47)';

  static final _languagePattern = RegExp(r'^[A-Za-z]{2,3}$');
  static final _scriptPattern = RegExp(r'^[A-Za-z]{4}$');
  static final _regionPattern = RegExp(r'^(?:[A-Za-z]{2}|\d{3})$');

  /// Deprecated codes some engines still use.
  static const _legacy = {'iw': 'he', 'jw': 'jv', 'in': 'id', 'ji': 'yi'};

  static const _asian = {'zh', 'ja', 'ko'};

  static const _complex = {
    'ar', 'he', 'fa', 'ur', 'ps', 'sd', 'ug', 'yi', 'dv', 'syr', 'ckb', //
    'hi', 'bn', 'pa', 'gu', 'or', 'ta', 'te', 'kn', 'ml', 'si', 'mr', 'ne',
    'sa', 'as', 'th', 'lo', 'km', 'my', 'bo', 'dz',
  };

  static const _defaultRegions = {
    'af': 'ZA',
    'am': 'ET',
    'ar': 'SA',
    'az': 'AZ',
    'be': 'BY',
    'bg': 'BG',
    'bn': 'BD',
    'bs': 'BA',
    'ca': 'ES',
    'cs': 'CZ',
    'cy': 'GB',
    'da': 'DK',
    'de': 'DE',
    'el': 'GR',
    'en': 'US',
    'es': 'ES',
    'et': 'EE',
    'eu': 'ES',
    'fa': 'IR',
    'fi': 'FI',
    'fil': 'PH',
    'fr': 'FR',
    'ga': 'IE',
    'gl': 'ES',
    'gu': 'IN',
    'he': 'IL',
    'hi': 'IN',
    'hr': 'HR',
    'hu': 'HU',
    'hy': 'AM',
    'id': 'ID',
    'is': 'IS',
    'it': 'IT',
    'ja': 'JP',
    'ka': 'GE',
    'kk': 'KZ',
    'km': 'KH',
    'kn': 'IN',
    'ko': 'KR',
    'lo': 'LA',
    'lt': 'LT',
    'lv': 'LV',
    'mk': 'MK',
    'ml': 'IN',
    'mn': 'MN',
    'mr': 'IN',
    'ms': 'MY',
    'mt': 'MT',
    'my': 'MM',
    'nb': 'NO',
    'ne': 'NP',
    'nl': 'NL',
    'nn': 'NO',
    'no': 'NO',
    'pa': 'IN',
    'pl': 'PL',
    'ps': 'AF',
    'pt': 'PT',
    'ro': 'RO',
    'ru': 'RU',
    'si': 'LK',
    'sk': 'SK',
    'sl': 'SI',
    'sq': 'AL',
    'sr': 'RS',
    'sv': 'SE',
    'sw': 'KE',
    'ta': 'IN',
    'te': 'IN',
    'th': 'TH',
    'tr': 'TR',
    'uk': 'UA',
    'ur': 'PK',
    'uz': 'UZ',
    'vi': 'VN',
    'zh': 'CN',
    'zu': 'ZA',
  };
}
