import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/phrasebook/models/phrase_collection.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/widgets/practice_texts.dart';

void main() {
  final l10n = AppLocalizationsEn();

  test('intervals read in minutes, hours, days, months and years', () {
    String text(Duration duration) => practiceIntervalText(l10n, duration);
    expect(text(const Duration(seconds: 20)), '1 min');
    expect(text(const Duration(seconds: 330)), '6 min');
    expect(text(const Duration(minutes: 59, seconds: 50)), '59 min');
    expect(text(const Duration(hours: 5)), '5 h');
    expect(text(const Duration(hours: 23, minutes: 40)), '1 day');
    expect(text(const Duration(days: 4)), '4 days');
    expect(text(const Duration(days: 45)), '1 month');
    expect(text(const Duration(days: 200)), '7 months');
    expect(text(const Duration(days: 800)), '2 years');
  });

  test('ratings, collections and language pairs', () {
    expect(
      [
        for (final rating in FsrsRating.values)
          practiceRatingLabel(l10n, rating),
      ],
      ['Again', 'Hard', 'Good', 'Easy'],
    );
    final epoch = DateTime(2026);
    final favorites = PhraseCollection(
      id: PhraseCollection.favoritesId,
      name: '',
      phraseIds: const [],
      createdAt: epoch,
      updatedAt: epoch,
    );
    expect(practiceCollectionName(l10n, favorites), 'Favorites');
    expect(practicePairText(favorites), isNull);
    final trip = PhraseCollection(
      id: 'c:1',
      name: 'Trip',
      sourceCode: 'en',
      targetCode: 'xx-unknown',
      phraseIds: const [],
      createdAt: epoch,
      updatedAt: epoch,
    );
    expect(practiceCollectionName(l10n, trip), 'Trip');
    expect(
      practicePairText(trip),
      '\u2068English\u2069 → \u2068xx-unknown\u2069',
    );
  });
}
