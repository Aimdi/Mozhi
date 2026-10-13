/// Conversion between the app's BCP-47-ish language codes and
/// LibreTranslate (Argos Translate) codes.
///
/// LibreTranslate mostly uses bare ISO 639-1 codes. Exceptions: Chinese is
/// `zh` (Simplified) and `zt` (Traditional) on older servers and
/// `zh-Hans`/`zh-Hant` on newer ones, Brazilian Portuguese is `pb` (newer:
/// `pt-BR`), Norwegian Bokmål is `nb`.
library;

import 'package:mt_api/src/language_tag.dart';

/// The LibreTranslate code for [appCode], e.g. `zh-CN` -> `zh`,
/// `zh-TW` -> `zt`, `pt-BR` -> `pb`, `no` -> `nb`, `en-US` -> `en`,
/// `auto` -> `auto`.
///
/// When [supported] (codes from `LibreTranslateClient.languages`) is given,
/// the first candidate it contains is returned in the server's spelling
/// (so `zh-CN` becomes `zh-Hans` on servers that list that code). Without a
/// match, or without [supported], the code understood by the most server
/// versions is returned.
///
/// Throws [ArgumentError] for an empty code.
String libreLanguageCode(String appCode, {Iterable<String>? supported}) {
  final tag = LanguageTag.parse(appCode);
  if (tag == null) {
    throw ArgumentError.value(appCode, 'appCode', 'Empty language code');
  }
  if (tag.isAuto) return 'auto';
  final (candidates, fallback) = _candidates(tag);
  if (supported == null) return fallback;
  final byLower = {for (final code in supported) code.toLowerCase(): code};
  for (final candidate in candidates) {
    if (byLower[candidate.toLowerCase()] case final code?) return code;
  }
  return fallback;
}

/// Codes to try in order, and the code to use when none of them is known to
/// be supported (the spelling understood by the most server versions).
(List<String>, String) _candidates(LanguageTag tag) {
  final region = tag.region;
  final List<String> aliases;
  switch (tag.language) {
    case 'zh' || 'zt':
      aliases = tag.isTraditionalChinese || tag.language == 'zt'
          ? const ['zt', 'zh-Hant', 'zh-TW']
          : const ['zh', 'zh-Hans', 'zh-CN'];
    case 'pt' || 'pb':
      aliases = region == 'br' || tag.language == 'pb'
          ? const ['pb', 'pt-BR', 'pt']
          : const ['pt', 'pt-PT'];
    case 'no' || 'nb':
      aliases = const ['nb', 'no'];
    case 'iw' || 'he':
      aliases = const ['he', 'iw'];
    case 'in' || 'id':
      aliases = const ['id', 'in'];
    case 'fil' || 'tl':
      aliases = const ['tl', 'fil'];
    default:
      // A variant (`sr-Latn`, `fr-CA`) is only used when the server lists it.
      final hasVariant = tag.script != null || region != null;
      return ([if (hasVariant) tag.toString(), tag.language], tag.language);
  }
  return (aliases, aliases.first);
}

/// The app code for a LibreTranslate code: `zh`/`zh-Hans` -> `zh-CN`,
/// `zt`/`zh-Hant` -> `zh-TW`, `pb`/`pt-BR` -> `pt-BR`, `nb` -> `no`,
/// `iw` -> `he`; anything else keeps its language (and canonical casing).
String appCodeFromLibre(String libreCode) {
  final tag = LanguageTag.parse(libreCode);
  if (tag == null) return libreCode.trim();
  return switch (tag.language) {
    'zt' => 'zh-TW',
    'zh' => tag.isTraditionalChinese ? 'zh-TW' : 'zh-CN',
    'pb' => 'pt-BR',
    'nb' => 'no',
    'iw' => 'he',
    'in' => 'id',
    _ => tag.toString(),
  };
}
