import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/models/phrase_collection.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:translation_repository/translation_repository.dart';

/// [interval] as shown on a rating button: minutes under an hour, hours
/// under a day, days under a month, months under two years, then years.
String practiceIntervalText(AppLocalizations l10n, Duration interval) {
  final minutes = interval.inSeconds / 60;
  if (minutes < 60) {
    return l10n.practiceIntervalMinutes(minutes.round().clamp(1, 59));
  }
  final hours = minutes / 60;
  if (hours < 23.5) return l10n.practiceIntervalHours(hours.round());
  final days = hours / 24;
  if (days < 30.5) return l10n.practiceIntervalDays(days.round().clamp(1, 30));
  final months = days / 30.44;
  if (months < 23.5) return l10n.practiceIntervalMonths(months.round());
  return l10n.practiceIntervalYears((days / 365.25).round());
}

/// The name of [rating].
String practiceRatingLabel(AppLocalizations l10n, FsrsRating rating) =>
    switch (rating) {
      FsrsRating.again => l10n.practiceRatingAgain,
      FsrsRating.hard => l10n.practiceRatingHard,
      FsrsRating.good => l10n.practiceRatingGood,
      FsrsRating.easy => l10n.practiceRatingEasy,
    };

/// The name of [collection] ("Favorites" for the built-in one).
String practiceCollectionName(
  AppLocalizations l10n,
  PhraseCollection collection,
) => collection.isFavorites ? l10n.historyFilterFavorites : collection.name;

/// The name of the language [code] in the UI language [uiLocale]
/// ([languageDisplayNameOf]; English by default, the code when unknown).
String practiceLanguageName(String code, {String uiLocale = 'en'}) =>
    languageDisplayNameOf(code, uiLocale);

/// "Portuguese → English" for a collection with a language pair, the names
/// in the UI language [uiLocale]; null without one.
String? practicePairText(
  PhraseCollection collection, {
  String uiLocale = 'en',
}) {
  final source = collection.sourceCode;
  final target = collection.targetCode;
  if (source == null || target == null) return null;
  return '${bidiIsolate(practiceLanguageName(source, uiLocale: uiLocale))} → '
      '${bidiIsolate(practiceLanguageName(target, uiLocale: uiLocale))}';
}
