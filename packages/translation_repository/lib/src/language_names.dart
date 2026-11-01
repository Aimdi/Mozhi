import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_names_data.dart';
import 'package:translation_repository/src/models/language.dart';

export 'package:translation_repository/src/language_names_data.dart'
    show languageNamesCldrVersion;

/// The name of [language] to show in an app whose UI language is
/// [uiLocale] (a language tag such as `de`, `pt_BR` or `zh-Hans-CN`; only
/// its language subtag counts): "Französisch" for French in German,
/// "英語" for English in Japanese.
///
/// The names are Unicode CLDR's ([languageNamesCldrVersion]), with the
/// first letter upper-cased for labels and lists ("Anglais", not
/// "anglais"); see `tool/language_names.py`. [language] is looked up by
/// its code, like [LanguageCatalog.byCode] (`zh` and `zh-Hans` name
/// Chinese (Simplified), `iw` Hebrew).
///
/// Falls back to [Language.name] (the catalogue's or the engine's English
/// name) in English, for an app language without names, a code outside
/// the catalogue and a language CLDR does not name. Custom languages
/// ("Pirate speak") and "Detect language" ([Language.auto]) are their
/// [Language.name] too: callers translate "Detect language" themselves.
///
/// Only for showing: prompts, engines and storage keep [Language.name].
String languageDisplayName(Language language, String uiLocale) {
  if (language.isCustom || language.isAuto) return language.name;
  return localizedLanguageName(language.code, uiLocale) ?? language.name;
}

/// The name of the catalogue language [code] in [uiLocale], like
/// [languageDisplayName]; the English name ([LanguageCatalog.nameOf]) when
/// there is none, and [code] itself when it is not in the catalogue.
String languageDisplayNameOf(String code, String uiLocale) =>
    localizedLanguageName(code, uiLocale) ?? LanguageCatalog.nameOf(code);

/// The CLDR name of the catalogue language [code] in [uiLocale], or null
/// when there is none to show instead of the English one (see
/// [languageDisplayName]).
String? localizedLanguageName(String code, String uiLocale) {
  final names = languageNamesData[_languageSubtag(uiLocale)];
  if (names == null) return null;
  final language = LanguageCatalog.byCode(code);
  return language == null ? null : names[language.code];
}

/// The app languages with names of their own (all but English).
Iterable<String> get languageNameLocales => languageNamesData.keys;

String _languageSubtag(String locale) =>
    locale.trim().split(RegExp('[-_]')).first.toLowerCase();
