import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/models/practice_card.dart';
import 'package:mozhi/practice/models/practice_item.dart';
import 'package:mozhi/practice/models/practice_settings.dart';

final _now = DateTime.utc(2026, 10, 22, 9);

Phrase _phrase(String source, String target, {String pronunciation = ''}) =>
    Phrase(
      id: 'p:$source$target',
      text: 'text',
      translation: 'translation',
      sourceCode: source,
      targetCode: target,
      createdAt: _now,
      updatedAt: _now,
      pronunciation: pronunciation,
    );

void main() {
  group(PracticeCard, () {
    test('a fresh card is new and not due', () {
      final card = PracticeCard.fresh('h:1', CardDirection.produce, _now);
      expect(card.id, 'h:1#p');
      expect(card.isNew, isTrue);
      expect(card.isDue(_now), isFalse);
      expect(card.reps, 0);
    });

    test('a review counts, a lapse in review too', () {
      final scheduler = FsrsScheduler(fuzz: false);
      var card = PracticeCard.fresh('h:1', CardDirection.recognize, _now);
      var now = _now;
      for (final rating in [FsrsRating.good, FsrsRating.good]) {
        card = card.reviewed(
          rating,
          scheduler.review(card.fsrs, rating, now),
          now,
        );
        now = card.fsrs.due;
      }
      expect(card.reps, 2);
      expect(card.lapses, 0);
      expect(card.firstReviewedAt, _now);
      expect(card.isDue(now), isTrue);
      final lapsed = card.reviewed(
        FsrsRating.again,
        scheduler.review(card.fsrs, FsrsRating.again, now),
        now,
      );
      expect(lapsed.lapses, 1);
      expect(lapsed.firstReviewedAt, _now);
      expect(lapsed.updatedAt, now);
      final touched = lapsed.touched(now.add(const Duration(hours: 1)));
      expect(touched.updatedAt, now.add(const Duration(hours: 1)));
      expect(touched.fsrs, lapsed.fsrs);

      expect(PracticeCard.fromJson(lapsed.toJson()), lapsed);
    });

    test('rejects what is not a card', () {
      expect(
        () => PracticeCard.fromJson(const {'phrase': 'x', 'direction': 'q'}),
        throwsFormatException,
      );
      final fresh = PracticeCard.fresh('h:1', CardDirection.recognize, _now);
      expect(
        PracticeCard.fromJson({...fresh.toJson()}..remove('updatedAt')),
        fresh,
      );
    });

    test('directions map their keys', () {
      expect(CardDirection.fromKey('r'), CardDirection.recognize);
      expect(CardDirection.fromKey('p'), CardDirection.produce);
      expect(CardDirection.fromKey('x'), isNull);
    });
  });

  group(PracticeSettings, () {
    test('round-trips and defaults', () {
      const defaults = PracticeSettings();
      expect(PracticeSettings.fromJson(defaults.toJson()), defaults);
      expect(defaults.includes('anything'), isTrue);
      final settings = PracticeSettings(
        collectionIds: const {'favorites'},
        directions: const {CardDirection.produce},
        newCardsPerDay: 5,
        desiredRetention: 0.85,
        typeAnswers: true,
        updatedAt: _now,
      );
      expect(PracticeSettings.fromJson(settings.toJson()), settings);
      expect(settings.includes('favorites'), isTrue);
      expect(settings.includes('c:1'), isFalse);
      expect(
        settings.copyWith(collectionIds: () => null).collectionIds,
        isNull,
      );
    });

    test('invalid values take their defaults or are clamped', () {
      final settings = PracticeSettings.fromJson(const {
        'collections': ['', 7, 'c:1'],
        'directions': ['x'],
        'newPerDay': 1000,
        'retention': 0.2,
        'updatedAt': 7,
      });
      expect(settings.collectionIds, {'c:1'});
      expect(settings.directions, const PracticeSettings().directions);
      expect(settings.newCardsPerDay, PracticeSettings.maxNewCardsPerDay);
      expect(settings.desiredRetention, FsrsScheduler.minDesiredRetention);
      expect(settings.updatedAt, isNull);
      final empty = PracticeSettings.fromJson(const {'newPerDay': 'x'});
      expect(empty.newCardsPerDay, PracticeSettings.defaultNewCardsPerDay);
      expect(empty.desiredRetention, FsrsScheduler.defaultDesiredRetention);
    });
  });

  group(PracticeItem, () {
    test('a recognise card shows the learned side first', () {
      final item = PracticeItem(
        card: PracticeCard.fresh('p:enpt', CardDirection.recognize, _now),
        phrase: _phrase('en', 'pt', pronunciation: 'trahn-ZLAH-sow'),
        foreignIsSource: false,
      );
      expect(item.frontText, 'translation');
      expect(item.frontCode, 'pt');
      expect(item.backText, 'text');
      expect(item.backCode, 'en');
      expect(item.pronunciation, 'trahn-ZLAH-sow');
      final produce = item.withCard(
        PracticeCard.fresh('p:enpt', CardDirection.produce, _now),
      );
      expect(produce.frontText, 'text');
      expect(produce.backText, 'translation');
      expect(produce.backCode, 'pt');
    });

    test('a learned source has no pronunciation of its own', () {
      final item = PracticeItem(
        card: PracticeCard.fresh('p:pten', CardDirection.recognize, _now),
        phrase: _phrase('pt', 'en', pronunciation: 'x'),
        foreignIsSource: true,
      );
      expect(item.foreignText, 'text');
      expect(item.foreignCode, 'pt');
      expect(item.nativeText, 'translation');
      expect(item.nativeCode, 'en');
      expect(item.pronunciation, isEmpty);
    });
  });

  group('userLanguageOf', () {
    test('is the app language when half of the phrases have it', () {
      expect(
        userLanguageOf([_phrase('en', 'pt'), _phrase('de', 'pt')], 'en-US'),
        'en',
      );
      expect(userLanguageOf(const [], 'fr'), 'fr');
    });

    test('else the language most phrases have', () {
      expect(
        userLanguageOf([
          _phrase('de', 'pt'),
          _phrase('pt', 'de'),
          _phrase('de', 'es'),
          _phrase('en', 'pt'),
        ], 'en'),
        'de',
      );
      expect(
        userLanguageOf([_phrase('und', 'und'), _phrase('ja', 'ko')], 'en'),
        'ja',
      );
    });
  });

  group('learnedSideOf', () {
    test('is the side not in the user language', () {
      expect(learnedSideOf(_phrase('en', 'pt'), 'en'), isFalse);
      expect(learnedSideOf(_phrase('pt-BR', 'en-GB'), 'en'), isTrue);
      expect(learnedSideOf(_phrase('ja', 'ko'), 'en'), isFalse);
      expect(learnedSideOf(_phrase('en', 'en'), 'en'), isFalse);
      expect(primaryLanguage('zh_Hant'), 'zh');
    });
  });
}
