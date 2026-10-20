import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// The languages the app's own texts are translated into
/// ([AppLocalizations.supportedLocales]) and how a choice of one
/// (`AppSettings.appLocale`) or the device's languages map to them.
abstract final class AppLanguages {
  /// Every language of the app's texts.
  static List<Locale> get supported => AppLocalizations.supportedLocales;

  /// The language used when none of the device's languages is supported.
  static const fallback = Locale('en');

  /// The supported locale the language tag [tag] (`de`, `pt-BR`, `zh_CN`)
  /// stands for: an exact match, else the first one with its language code.
  /// Null for null, blank or unsupported tags (the device's language is
  /// then used).
  static Locale? resolve(String? tag) {
    final normalized = tag?.trim().replaceAll('_', '-').toLowerCase() ?? '';
    if (normalized.isEmpty) return null;
    for (final locale in supported) {
      if (locale.toLanguageTag().toLowerCase() == normalized) return locale;
    }
    final language = normalized.split('-').first;
    for (final locale in supported) {
      if (locale.languageCode == language) return locale;
    }
    return null;
  }

  /// The language's name in itself ("Deutsch", "日本語"), or its language
  /// tag when the language catalogue does not know it.
  static String nativeName(Locale locale) {
    final tag = locale.toLanguageTag();
    return LanguageCatalog.byCode(tag)?.nativeName ?? tag;
  }

  /// [supported], sorted by [nativeName] (Latin script first, as in
  /// Android's language list).
  static List<Locale> get byName => [...supported]
    ..sort(
      (a, b) =>
          nativeName(a).toLowerCase().compareTo(nativeName(b).toLowerCase()),
    );

  /// `MaterialApp.localeListResolutionCallback` for the device's languages
  /// ([preferred]): the usual matching ([basicLocaleListResolution]) when
  /// one of them is supported, else [fallback] (English) instead of the
  /// first supported locale (which is Arabic, alphabetically).
  static Locale resolveDeviceLocales(
    List<Locale>? preferred,
    Iterable<Locale> supported,
  ) {
    final languages = {for (final locale in supported) locale.languageCode};
    final known =
        preferred?.any((locale) => languages.contains(locale.languageCode)) ??
        false;
    if (known) return basicLocaleListResolution(preferred, supported);
    return supported.contains(fallback) ? fallback : supported.first;
  }
}
