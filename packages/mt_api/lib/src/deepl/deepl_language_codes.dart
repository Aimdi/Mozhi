/// Conversion between the app's BCP-47-ish language codes (`en`, `pt-BR`,
/// `zh-CN`, `zh-TW`, `no`, `es-419`) and DeepL codes.
///
/// DeepL facts: source codes are bare upper-case languages (`EN`, `PT`,
/// `ZH`, `NB`); target codes add variants for English (`EN-US`, `EN-GB`),
/// Portuguese (`PT-BR`, `PT-PT`), Spanish (`ES-419`) and Chinese
/// (`ZH-HANS`, `ZH-HANT`). The plain `EN`, `PT` and `ZH` targets are
/// deprecated. Norwegian Bokmål is `NB`.
library;

import 'package:mt_api/src/language_tag.dart';

/// Regions whose English follows US spelling; every other region maps to
/// `EN-GB`.
const _usEnglishRegions = {'us', 'ca', 'ph', 'pr', 'um', 'vi', 'as', 'gu'};

/// Latin American (and US) Spanish regions, served by `ES-419`.
const _latinAmericanSpanishRegions = {
  '419', 'mx', 'ar', 'bo', 'cl', 'co', 'cr', 'cu', 'do', 'ec', 'gt', 'hn', //
  'ni', 'pa', 'pe', 'pr', 'py', 'sv', 'us', 'uy', 've',
};

/// The DeepL target code for [appCode], e.g. `en` -> `EN-US`,
/// `en-AU` -> `EN-GB`, `pt` -> `PT-BR`, `pt-PT` -> `PT-PT`,
/// `zh-CN` -> `ZH-HANS`, `zh-TW`/`zh-HK` -> `ZH-HANT`, `es-MX` -> `ES-419`,
/// `no` -> `NB`, `iw` -> `HE`, `fr-CA` -> `FR`.
///
/// Bare `pt` maps to Brazilian Portuguese because that is what other
/// engines (Google, Mozhi) produce for `pt`.
///
/// When [supported] (codes from `DeeplClient.languages`) is given, the first
/// candidate it contains is returned in the server's spelling, so a region
/// the server does not know falls back to the next variant or the bare
/// language (and a region DeepL adds later is used as is). Without a match,
/// or without [supported], the preferred candidate is returned.
///
/// Throws [ArgumentError] for an empty code or `auto`.
String deeplTargetCode(String appCode, {Iterable<String>? supported}) {
  final tag = LanguageTag.parse(appCode);
  if (tag == null || tag.isAuto) {
    throw ArgumentError.value(appCode, 'appCode', 'Not a target language');
  }
  final (candidates, fallback) = _targetCandidates(tag);
  if (supported == null) return fallback;
  final byUpper = {for (final code in supported) code.toUpperCase(): code};
  for (final candidate in candidates) {
    if (byUpper[candidate] case final code?) return code;
  }
  return fallback;
}

/// Target codes to try in order, and the code to use when none of them is
/// known to be supported.
(List<String>, String) _targetCandidates(LanguageTag tag) {
  final base = _deeplBase(tag.language);
  final region = tag.region;
  final List<String> variants;
  switch (base) {
    case 'EN':
      variants = region == null || _usEnglishRegions.contains(region)
          ? const ['EN-US', 'EN-GB', 'EN']
          : const ['EN-GB', 'EN-US', 'EN'];
    case 'PT':
      variants = region == null || region == 'br'
          ? const ['PT-BR', 'PT-PT', 'PT']
          : const ['PT-PT', 'PT-BR', 'PT'];
    case 'ZH':
      variants = tag.isTraditionalChinese
          ? const ['ZH-HANT', 'ZH']
          : const ['ZH-HANS', 'ZH'];
    case 'ES':
      variants = region != null && _latinAmericanSpanishRegions.contains(region)
          ? const ['ES-419', 'ES']
          : const ['ES', 'ES-419'];
    default:
      // Unknown variants (`fr-CA`, `sr-Latn`) are only used when the server
      // lists them.
      final variant = tag.script ?? region;
      return (
        [if (variant != null) '$base-${variant.toUpperCase()}', base],
        base,
      );
  }
  return (variants, variants.first);
}

/// The DeepL source code for [appCode] (`en-US` -> `EN`, `zh-TW` -> `ZH`,
/// `no` -> `NB`), or `null` for `auto`/empty, meaning "detect".
String? deeplSourceCode(String appCode) {
  final tag = LanguageTag.parse(appCode);
  if (tag == null || tag.isAuto) return null;
  return _deeplBase(tag.language);
}

/// The app code for a DeepL code (source, target or detected):
/// `EN` -> `en`, `EN-GB` -> `en-GB`, `ZH`/`ZH-HANS` -> `zh-CN`,
/// `ZH-HANT` -> `zh-TW`, `NB` -> `no`, `ES-419` -> `es-419`.
String appCodeFromDeepl(String deeplCode) {
  final tag = LanguageTag.parse(deeplCode);
  if (tag == null) return deeplCode.trim();
  return switch (tag.language) {
    'zh' => tag.isTraditionalChinese ? 'zh-TW' : 'zh-CN',
    'nb' => 'no',
    _ => tag.toString(),
  };
}

/// Upper-case DeepL base code, with legacy and macro-language aliases.
String _deeplBase(String language) => switch (language) {
  'no' || 'nob' => 'NB',
  'iw' => 'HE',
  'in' => 'ID',
  _ => language.toUpperCase(),
};
