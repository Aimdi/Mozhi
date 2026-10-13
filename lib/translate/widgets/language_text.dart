import 'package:intl/intl.dart' show Bidi;
import 'package:material_ui/material_ui.dart';
import 'package:translation_repository/translation_repository.dart';

/// Scripts written right to left (ISO 15924 codes, lower case).
const _rtlScripts = {
  'adlm',
  'arab',
  'hebr',
  'mand',
  'nkoo',
  'rohg',
  'samr',
  'syrc',
  'thaa',
};

/// Scripts written left to right that some RTL-default languages also use
/// (e.g. `ku-latn`, `pa-guru`, `sd-deva`, `uz-latn`).
const _ltrScripts = {'cyrl', 'deva', 'guru', 'latn'};

/// Languages written right to left by default (primary subtag).
const _rtlLanguages = {
  'ar', 'arc', 'arz', 'ary', 'arq', 'aeb', 'apc', 'apd', 'acm', 'acq', //
  'afb', 'ajp', 'ayl', 'azb', 'bal', 'bqi', 'ckb', 'dv', 'fa', 'glk', //
  'he', 'iw', 'khw', 'ks', 'lrc', 'mzn', 'nqo', 'pnb', 'prs', 'ps', //
  'sd', 'skr', 'syr', 'ug', 'ur', 'yi', 'ji',
};

/// Whether text in the language [code] (a BCP-47 tag such as `ar`,
/// `fa-IR`, `pa-Arab` or `ku-Latn`) is written right to left.
bool isRtlLanguageCode(String? code) {
  if (code == null) return false;
  final parts = code.trim().toLowerCase().split(RegExp('[-_]'));
  if (parts.first.isEmpty) return false;
  for (final part in parts.skip(1)) {
    if (part.length != 4) continue;
    if (_rtlScripts.contains(part)) return true;
    if (_ltrScripts.contains(part)) return false;
  }
  return _rtlLanguages.contains(parts.first);
}

/// Direction of text in the language [code]; null when unknown (no code,
/// `auto` or a free-form custom "language"), so the ambient direction
/// applies.
TextDirection? textDirectionForCode(String? code) {
  final normalized = code?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized == Language.auto.code) return null;
  return isRtlLanguageCode(normalized) ? TextDirection.rtl : TextDirection.ltr;
}

/// Direction of text in [language] (null for `auto` and custom languages).
TextDirection? textDirectionForLanguage(Language language) {
  if (language.isAuto || language.isCustom) return null;
  return textDirectionForCode(language.code);
}

/// Direction guessed from the characters of [text] (null when empty).
TextDirection? textDirectionForText(String text) {
  if (text.trim().isEmpty) return null;
  return Bidi.detectRtlDirectionality(text)
      ? TextDirection.rtl
      : TextDirection.ltr;
}

/// [Locale] for the BCP-47 [code] (`ja`, `zh-Hant`, `pt-BR`, `es-419`), so
/// screen readers pick a matching voice and the right glyphs are used;
/// null for `auto`, empty or malformed codes.
Locale? localeForCode(String? code) {
  final normalized = code?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  final parts = normalized.split(RegExp('[-_]'));
  final language = parts.first.toLowerCase();
  if (language == Language.auto.code ||
      !RegExp(r'^[a-z]{2,3}$').hasMatch(language)) {
    return null;
  }
  String? script;
  String? country;
  for (final part in parts.skip(1)) {
    if (script == null && country == null && part.length == 4) {
      if (!RegExp(r'^[A-Za-z]{4}$').hasMatch(part)) return null;
      script = part[0].toUpperCase() + part.substring(1).toLowerCase();
    } else if (country == null &&
        RegExp(r'^([A-Za-z]{2}|\d{3})$').hasMatch(part)) {
      country = part.toUpperCase();
    } else {
      // Variants and extensions do not change the voice; ignore them.
      break;
    }
  }
  return Locale.fromSubtags(
    languageCode: language,
    scriptCode: script,
    countryCode: country,
  );
}

/// [Locale] for [language] (null for `auto` and custom languages).
Locale? localeForLanguage(Language language) {
  if (language.isAuto || language.isCustom) return null;
  return localeForCode(language.code);
}
