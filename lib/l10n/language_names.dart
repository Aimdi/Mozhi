import 'package:flutter/widgets.dart';
import 'package:mozhi/l10n/gen/app_localizations.dart';
import 'package:translation_repository/translation_repository.dart';

/// Language names in the app's UI language ("Französisch" for French in
/// German), from [languageDisplayName].
///
/// The UI language is the one of the app's texts
/// ([AppLocalizations.localeName]), so the names always match them (also
/// when the texts fell back to English). Only for showing: prompts,
/// engines, storage and exports keep [Language.name].
extension LanguageNamesX on BuildContext {
  /// The name of [language] to show: in the UI language, "Detect
  /// language" (translated) for [Language.auto], a custom language's own
  /// text ([languageNameIn]).
  String languageName(Language language) =>
      languageNameIn(AppLocalizations.of(this), language);

  /// The name of the catalogue language [code] to show, like
  /// [languageName]; [code] itself when it is not in the catalogue
  /// (like [LanguageCatalog.nameOf]).
  String languageNameOf(String code) =>
      languageDisplayNameOf(code, AppLocalizations.of(this).localeName);

  /// The app's UI language for [languageDisplayName].
  String get languageNamesLocale => AppLocalizations.of(this).localeName;
}

/// The name of [language] to show with the app's texts [l10n]: in their
/// language ([languageDisplayName]), "Detect language" (translated) for
/// [Language.auto], a custom language's own text. For code that has the
/// texts but no `BuildContext`; widgets use `context.languageName`.
String languageNameIn(AppLocalizations l10n, Language language) =>
    language.isAuto
    ? l10n.translateDetectLanguage
    : languageDisplayName(language, l10n.localeName);
