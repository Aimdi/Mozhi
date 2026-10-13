import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Maps the app's language codes (catalogue codes such as `zh-CN`, `pt-BR`,
/// `nb`, `iw`, `fil`) onto ML Kit's on-device translation codes and back.
abstract final class MlKitLanguageCodes {
  /// BCP-47 codes of every ML Kit translation model (59 languages, e.g.
  /// `af`, `sq`, `ar`, ..., `zh`, `cy`).
  static final Set<String> supported = Set.unmodifiable({
    for (final language in TranslateLanguage.values) language.bcpCode,
  });

  /// Legacy, macro-language and ISO 639-3 codes whose ML Kit model has a
  /// different code. Keys are lower-case primary subtags.
  static const _aliases = <String, String>{
    'iw': 'he',
    'in': 'id',
    'nb': 'no',
    'nn': 'no',
    'nob': 'no',
    'nno': 'no',
    'fil': 'tl',
    'mo': 'ro',
    'cmn': 'zh',
    'zho': 'zh',
    'zsm': 'ms',
    'msa': 'ms',
    'pes': 'fa',
    'prs': 'fa',
    'fas': 'fa',
    'arb': 'ar',
    'ara': 'ar',
    'swh': 'sw',
    'swa': 'sw',
    'ekk': 'et',
    'est': 'et',
    'lvs': 'lv',
    'lav': 'lv',
    'eng': 'en',
    'deu': 'de',
    'ger': 'de',
    'fra': 'fr',
    'fre': 'fr',
    'spa': 'es',
    'por': 'pt',
    'ita': 'it',
    'rus': 'ru',
    'jpn': 'ja',
    'kor': 'ko',
  };

  /// Codes that look like a supported language but are a different one
  /// (Cantonese is not ML Kit's Chinese model).
  static const _excluded = <String>{'zh-yue', 'auto', 'und'};

  /// The ML Kit model code for [code], or null when ML Kit has no model for
  /// that language.
  ///
  /// Case and `_` separators are ignored, regional and script variants fall
  /// back to their language (`en-GB`, `pt-BR`, `zh-Hant`, `zh-TW`,
  /// `ar-EG`, `fr_CA` -> `en`, `pt`, `zh`, `zh`, `ar`, `fr`) and legacy
  /// codes are mapped (`iw` -> `he`, `nb`/`nn` -> `no`, `fil` -> `tl`,
  /// `in` -> `id`). `auto`, empty and unknown codes return null.
  static String? toMlKit(String code) {
    final key = _key(code);
    if (key.isEmpty || _isExcluded(key)) return null;
    if (supported.contains(key)) return key;
    final primary = key.split('-').first;
    final mapped = _aliases[primary] ?? primary;
    return supported.contains(mapped) ? mapped : null;
  }

  /// Whether ML Kit can translate [code] (see [toMlKit]).
  static bool isSupported(String code) => toMlKit(code) != null;

  /// Normalises a language-identification result: `und` and empty codes
  /// become null, legacy primary subtags are mapped (`iw` -> `he`,
  /// `fil` -> `tl`) and casing follows BCP-47 (`ZH_latn` -> `zh-Latn`).
  ///
  /// Script subtags are kept: ML Kit reports romanised text as e.g.
  /// `ja-Latn` or `hi-Latn`.
  static String? normalizeIdentified(String code) {
    final key = _key(code);
    if (key.isEmpty || key == 'und') return null;
    final parts = key.split('-');
    final primary = parts.first;
    parts[0] = primary.length < 4 ? (_aliases[primary] ?? primary) : primary;
    return [
      parts.first,
      for (final part in parts.skip(1)) _subtagCase(part),
    ].join('-');
  }

  static bool _isExcluded(String key) => _excluded.any(
    (excluded) => key == excluded || key.startsWith('$excluded-'),
  );

  static String _key(String code) => code
      .trim()
      .replaceAll('_', '-')
      .toLowerCase()
      .split('-')
      .where((part) => part.isNotEmpty)
      .join('-');

  static String _subtagCase(String subtag) {
    if (subtag.length == 4) {
      return '${subtag[0].toUpperCase()}${subtag.substring(1)}';
    }
    if (subtag.length == 2) return subtag.toUpperCase();
    return subtag;
  }
}
