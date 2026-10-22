import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/practice/data/fsrs.dart';

const FsrsRating _again = FsrsRating.again;
const FsrsRating _hard = FsrsRating.hard;
const FsrsRating _good = FsrsRating.good;
const FsrsRating _easy = FsrsRating.easy;

/// 2022-11-29 12:30 UTC, the start of the reference tests.
final _start = DateTime.utc(2022, 11, 29, 12, 30);

/// Reviews a new card with [ratings], each when the card is due, and
/// returns the card after each review.
List<FsrsCard> _sequence(FsrsScheduler scheduler, List<FsrsRating> ratings) {
  var card = FsrsCard.fresh(_start);
  var now = _start;
  final cards = <FsrsCard>[];
  for (final rating in ratings) {
    card = scheduler.review(card, rating, now);
    cards.add(card);
    now = card.due;
  }
  return cards;
}

/// The intervals of [cards] in whole days (rounded down, as the reference
/// tests count them).
List<int> _days(List<FsrsCard> cards) => [
  for (final card in cards) card.due.difference(card.lastReview!).inDays,
];

void main() {
  group(FsrsScheduler, () {
    final scheduler = FsrsScheduler(fuzz: false);

    // Golden values of py-fsrs v5.1.3 (MIT), tests/test_basic.py
    // `test_review_card` and `test_custom_scheduler_args`.
    test('schedules the reference sequence of py-fsrs', () {
      final cards = _sequence(scheduler, [
        _good, _good, _good, _good, _good, _good, //
        _again, _again, _good, _good, _good, _good, _good,
      ]);
      expect(_days(cards), [0, 4, 14, 44, 125, 328, 0, 0, 7, 16, 34, 71, 142]);
      expect(cards.first.due.difference(_start), const Duration(minutes: 10));
      expect(cards[6].state, FsrsState.relearning);
      expect(cards.last.state, FsrsState.review);
    });

    // py-fsrs v5.1.3 `test_memo_state` (the default scheduler, with fuzz:
    // the memory state does not depend on it).
    test('reaches the reference memory state', () {
      final fuzzy = FsrsScheduler();
      var card = FsrsCard.fresh(_start);
      var now = _start;
      const ratings = [_again, _good, _good, _good, _good, _good];
      const intervals = [0, 0, 1, 3, 8, 21];
      for (var i = 0; i < ratings.length; i++) {
        card = fuzzy.review(card, ratings[i], now, random: math.Random(i));
        now = now.add(Duration(days: intervals[i]));
      }
      card = fuzzy.review(card, _good, now, random: math.Random(7));
      expect(card.stability!.round(), 49);
      expect(card.difficulty, closeTo(7.0866, 0.00005));
    });

    // py-fsrs v5.1.3 `test_repeated_correct_reviews`.
    test('Easy over and over brings the difficulty down to 1', () {
      var card = FsrsCard.fresh(_start);
      for (var i = 0; i < 10; i++) {
        card = scheduler.review(
          card,
          _easy,
          _start.add(Duration(microseconds: i)),
        );
      }
      expect(card.difficulty, 1);
    });

    // Values computed with py-fsrs v5.1.3 (fuzz off).
    test('matches the reference stability and difficulty', () {
      final cards = _sequence(scheduler, [
        _hard, _good, _easy, _hard, _again, _good, _easy, _good, //
      ]);
      expect(
        [for (final card in cards) card.due.difference(card.lastReview!)],
        const [
          Duration(seconds: 330),
          Duration(minutes: 10),
          Duration(days: 4),
          Duration(days: 6),
          Duration(minutes: 10),
          Duration(days: 2),
          Duration(days: 12),
          Duration(days: 29),
        ],
      );
      const stabilities = [
        1.18385,
        1.6665899525670382,
        3.9327437961955707,
        5.95305707255471,
        1.5374706318682194,
        2.1644068990484184,
        11.508708839146909,
        28.50879767217746,
      ];
      const difficulties = [
        6.488305268471453,
        6.473291771547592,
        5.888712577239973,
        6.540513337928958,
        7.64281391575462,
        7.622489679053257,
        7.218242896198925,
        7.199871686187518,
      ];
      for (var i = 0; i < cards.length; i++) {
        expect(cards[i].stability, closeTo(stabilities[i], 1e-9));
        expect(cards[i].difficulty, closeTo(difficulties[i], 1e-9));
      }
    });

    test('a new card: Again 1 min, Hard 5.5 min, Good 10 min, Easy 16 d', () {
      final preview = scheduler.preview(
        FsrsCard.fresh(_start),
        _start,
        seed: 1,
      );
      expect(
        {
          for (final MapEntry(:key, :value) in preview.entries)
            key: value.due.difference(_start),
        },
        {
          _again: const Duration(minutes: 1),
          _hard: const Duration(seconds: 330),
          _good: const Duration(minutes: 10),
          _easy: const Duration(days: 16),
        },
      );
      expect(preview[_again]!.state, FsrsState.learning);
      expect(preview[_again]!.step, 0);
      expect(preview[_good]!.step, 1);
      expect(preview[_easy]!.state, FsrsState.review);
      expect(preview[_easy]!.step, isNull);
      expect(preview[_easy]!.stability, 15.69105);
      expect(preview[_easy]!.difficulty, closeTo(3.2245015893713678, 1e-12));
    });

    test('a review card: what each rating does', () {
      final review = _sequence(scheduler, [_good, _good]).last;
      expect(review.stability, closeTo(4.466858064362218, 1e-12));
      final preview = scheduler.preview(review, review.due, seed: 1);
      expect(preview[_again]!.state, FsrsState.relearning);
      expect(
        preview[_again]!.due.difference(review.due),
        const Duration(minutes: 10),
      );
      expect(preview[_again]!.stability, closeTo(1.2976302777410647, 1e-12));
      expect(
        preview[_hard]!.due.difference(review.due),
        const Duration(days: 7),
      );
      expect(
        preview[_good]!.due.difference(review.due),
        const Duration(days: 14),
      );
      expect(
        preview[_easy]!.due.difference(review.due),
        const Duration(days: 34),
      );
      expect(preview[_easy]!.difficulty, closeTo(4.500033631888484, 1e-12));
    });

    test('a late review uses the lower retrievability', () {
      final review = _sequence(scheduler, [_good, _good]).last;
      final late = review.due.add(const Duration(days: 26));
      expect(
        scheduler.retrievability(review, late),
        closeTo(0.62312994191238, 1e-12),
      );
      final next = scheduler.review(review, _good, late);
      expect(next.stability, closeTo(51.490143359341914, 1e-9));
      expect(next.due.difference(late), const Duration(days: 51));
    });

    test('a higher desired retention gives shorter intervals', () {
      List<int> intervals(double retention) => _days(
        _sequence(FsrsScheduler(fuzz: false, desiredRetention: retention), [
          _good,
          _good,
          _good,
          _good,
        ]),
      );
      expect(intervals(0.8), [0, 11, 66, 337]);
      expect(intervals(0.9), [0, 4, 14, 44]);
      expect(intervals(0.95), [0, 2, 4, 9]);
    });

    test('keeps the desired retention within its range', () {
      expect(FsrsScheduler(desiredRetention: 0.5).desiredRetention, 0.7);
      expect(FsrsScheduler(desiredRetention: 1).desiredRetention, 0.97);
    });

    test('caps intervals at the maximum interval', () {
      final capped = FsrsScheduler(fuzz: false, maximumInterval: 100);
      expect(_days(_sequence(capped, [_easy, _easy, _easy, _easy])), [
        16,
        100,
        100,
        100,
      ]);
      expect(capped.intervalDays(0.01), 1);
    });

    test('rejects invalid weights and maximum intervals', () {
      expect(() => FsrsScheduler(weights: [1, 2]), throwsArgumentError);
      expect(() => FsrsScheduler(maximumInterval: 0), throwsArgumentError);
    });

    group('learning steps', () {
      test('Hard with one step waits one and a half steps', () {
        final one = FsrsScheduler(
          fuzz: false,
          learningSteps: const [Duration(minutes: 10)],
        );
        final card = one.review(FsrsCard.fresh(_start), _hard, _start);
        expect(card.due.difference(_start), const Duration(minutes: 15));
        expect(card.step, 0);
        final good = one.review(card, _good, card.due);
        expect(good.state, FsrsState.review);
      });

      test('Hard on a later step repeats it; Again starts over', () {
        final three = FsrsScheduler(
          fuzz: false,
          learningSteps: const [
            Duration(minutes: 1),
            Duration(minutes: 10),
            Duration(hours: 1),
          ],
        );
        var card = three.review(FsrsCard.fresh(_start), _good, _start);
        expect(card.step, 1);
        card = three.review(card, _hard, card.due);
        expect(card.step, 1);
        expect(
          card.due.difference(card.lastReview!),
          const Duration(minutes: 10),
        );
        card = three.review(card, _good, card.due);
        expect(card.step, 2);
        expect(card.due.difference(card.lastReview!), const Duration(hours: 1));
        card = three.review(card, _again, card.due);
        expect(card.state, FsrsState.learning);
        expect(card.step, 0);
        expect(
          card.due.difference(card.lastReview!),
          const Duration(minutes: 1),
        );
      });

      test('without steps, a new card goes to review at once', () {
        final none = FsrsScheduler(fuzz: false, learningSteps: const []);
        final card = none.review(FsrsCard.fresh(_start), _again, _start);
        expect(card.state, FsrsState.review);
        expect(card.due.difference(_start).inDays, greaterThanOrEqualTo(1));
      });

      test('a card past the last step graduates on a pass', () {
        final card = FsrsCard(
          due: _start,
          state: FsrsState.learning,
          step: 5,
          stability: 3,
          difficulty: 5,
          lastReview: _start,
        );
        expect(scheduler.review(card, _hard, _start).state, FsrsState.review);
        expect(scheduler.review(card, _again, _start).step, 0);
      });
    });

    group('relearning steps', () {
      FsrsCard lapsed(FsrsScheduler scheduler) {
        final review = _sequence(scheduler, [_good, _good, _good]).last;
        return scheduler.review(review, _again, review.due);
      }

      test('Again in review relearns, Good graduates again', () {
        final card = lapsed(scheduler);
        expect(card.state, FsrsState.relearning);
        expect(card.step, 0);
        final again = scheduler.review(card, _again, card.due);
        expect(again.state, FsrsState.relearning);
        expect(again.due.difference(card.due), const Duration(minutes: 10));
        final good = scheduler.review(again, _good, again.due);
        expect(good.state, FsrsState.review);
        expect(good.step, isNull);
        expect(
          good.due.difference(again.due).inHours,
          greaterThanOrEqualTo(24),
        );
      });

      test('Hard on the first of two steps waits halfway', () {
        final two = FsrsScheduler(
          fuzz: false,
          relearningSteps: const [Duration(minutes: 1), Duration(minutes: 9)],
        );
        final card = lapsed(two);
        final hard = two.review(card, _hard, card.due);
        expect(hard.due.difference(card.due), const Duration(minutes: 5));
        final good = two.review(hard, _good, hard.due);
        expect(good.state, FsrsState.relearning);
        expect(good.step, 1);
        final easy = two.review(good, _easy, good.due);
        expect(easy.state, FsrsState.review);
      });

      test('without relearning steps, Again stays in review', () {
        final none = FsrsScheduler(fuzz: false, relearningSteps: const []);
        final card = lapsed(none);
        expect(card.state, FsrsState.review);
        expect(
          card.due.difference(card.lastReview!).inDays,
          greaterThanOrEqualTo(1),
        );
      });
    });

    group('fuzz', () {
      test('ranges match py-fsrs', () {
        expect(
          {
            for (final days in [3, 4, 7, 10, 20, 50, 100, 365])
              days: scheduler.fuzzRange(days),
          },
          {
            3: (2, 4),
            4: (3, 5),
            7: (5, 9),
            10: (8, 12),
            20: (17, 23),
            50: (46, 54),
            100: (93, 107),
            365: (345, 385),
          },
        );
        expect(FsrsScheduler(maximumInterval: 30).fuzzRange(50), (30, 30));
      });

      test('keeps fuzzed intervals within the range', () {
        final fuzzy = FsrsScheduler();
        final review = _sequence(FsrsScheduler(fuzz: false), [
          _good,
          _good,
        ]).last;
        final seen = <int>{};
        for (var seed = 0; seed < 200; seed++) {
          final next = fuzzy.review(
            review,
            _good,
            review.due,
            random: math.Random(seed),
          );
          seen.add(next.due.difference(review.due).inDays);
        }
        // 14 days: 12 to 16.
        expect(seen, {12, 13, 14, 15, 16});
      });

      test('the same seed previews the same intervals', () {
        final fuzzy = FsrsScheduler();
        final review = _sequence(FsrsScheduler(fuzz: false), [
          _good,
          _good,
        ]).last;
        final first = fuzzy.preview(review, review.due, seed: 42);
        final second = fuzzy.preview(review, review.due, seed: 42);
        expect(first, second);
      });

      test('short intervals are not fuzzed', () {
        final fuzzy = FsrsScheduler(desiredRetention: 0.97);
        final card = fuzzy.review(FsrsCard.fresh(_start), _good, _start);
        final review = fuzzy.review(card, _good, card.due);
        expect(review.due.difference(card.due).inDays, lessThanOrEqualTo(2));
      });
    });

    test('rounds ties to even, as Python does', () {
      expect(FsrsScheduler.roundHalfEven(2.5), 2);
      expect(FsrsScheduler.roundHalfEven(3.5), 4);
      expect(FsrsScheduler.roundHalfEven(3.4), 3);
      expect(FsrsScheduler.roundHalfEven(3.6), 4);
    });

    test('a new card has no retrievability', () {
      expect(scheduler.retrievability(FsrsCard.fresh(_start), _start), 0);
    });
  });

  group(FsrsCard, () {
    test('round-trips through JSON', () {
      final card = FsrsScheduler(fuzz: false)
          .review(FsrsCard.fresh(_start), _good, _start);
      expect(FsrsCard.fromJson(card.toJson()), card);
      final fresh = FsrsCard.fresh(_start);
      expect(fresh.isNew, isTrue);
      expect(FsrsCard.fromJson(fresh.toJson()), fresh);
    });

    test('rejects what is not a card', () {
      expect(
        () => FsrsCard.fromJson(const {'state': 'nope', 'due': '2022'}),
        throwsFormatException,
      );
      expect(
        () => FsrsCard.fromJson(const {'state': 'review'}),
        throwsFormatException,
      );
    });
  });

  group(FsrsRating, () {
    test('maps grades 1 to 4', () {
      expect(FsrsRating.fromGrade(1), _again);
      expect(FsrsRating.fromGrade(4), _easy);
      expect(FsrsRating.fromGrade(5), isNull);
    });
  });

  group(FsrsState, () {
    test('maps keys', () {
      for (final state in FsrsState.values) {
        expect(FsrsState.fromKey(state.key), state);
      }
      expect(FsrsState.fromKey('x'), isNull);
    });
  });
}
