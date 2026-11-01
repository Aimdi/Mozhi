import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:translation_repository/translation_repository.dart';

/// The [PhrasebookRepository] provided above [context], or null (none in
/// tests and screens that do without: the phrasebook's entry points are
/// then hidden).
PhrasebookRepository? maybePhrasebookRepository(BuildContext context) {
  try {
    return context.read<PhrasebookRepository>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The name of the phrase language [code] in the UI language
/// ([languageDisplayNameOf]; "Unknown language" for
/// [Phrase.unknownLanguage]).
String phrasebookLanguageName(AppLocalizations l10n, String code) =>
    code == Phrase.unknownLanguage
    ? l10n.phrasebookUnknownLanguage
    : languageDisplayNameOf(code, l10n.localeName);

/// "English → Portuguese", both names bidi-isolated.
String phrasebookPairLabel(
  AppLocalizations l10n,
  String sourceCode,
  String targetCode,
) => l10n.historyLanguagePair(
  bidiIsolate(phrasebookLanguageName(l10n, sourceCode)),
  bidiIsolate(phrasebookLanguageName(l10n, targetCode)),
);

/// What the app calls [collection]: "Favorites" for the built-in one, the
/// user's name otherwise.
String phrasebookCollectionName(
  AppLocalizations l10n,
  PhraseCollection collection,
) => collection.isFavorites ? l10n.phrasebookFavorites : collection.name;

/// A [Locale] for the phrase language [code], or null when unknown.
Locale? phrasebookLocale(String code) =>
    code == Phrase.unknownLanguage ? null : localeForCode(code);

/// The direction of text in the phrase language [code], or null when
/// unknown (the text's own characters decide then).
TextDirection? phrasebookTextDirection(String code, String text) =>
    (code == Phrase.unknownLanguage ? null : textDirectionForCode(code)) ??
    textDirectionForText(text);
