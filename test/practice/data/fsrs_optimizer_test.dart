import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/fsrs_optimizer.dart';
import 'package:mozhi/practice/models/practice_review_log.dart';

/// Generates deterministic multi-review logs for [cardCount] cards using
/// [trueWeights] to determine recall probabilities at each review interval.
List<PracticeReviewLog> _syntheticLogs({
  required List<double> trueWeights,
  required int cardCount,
  required int reviewsPerCard,
  int seed = 42,
}) {
  final rng = math.Random(seed);
  final trueScheduler = FsrsScheduler(weights: trueWeights, fuzz: false);
  final defaultScheduler = FsrsScheduler(fuzz: false);
  final start = DateTime.utc(2026, 1, 1, 9);
  final logs = <PracticeReviewLog>[];

  for (var c = 0; c < cardCount; c++) {
    final key = 'c:$c#r';
    var now = start.add(Duration(hours: c));
    var trueCard = FsrsCard.fresh(now);
    var scheduledCard = FsrsCard.fresh(now);

    for (var r = 0; r < reviewsPerCard; r++) {
      final elapsed = r == 0
          ? 0.0
          : math.max<double>(
              0,
              now.difference(trueCard.lastReview!).inMicroseconds /
                  Duration.microsecondsPerDay,
            );
      final FsrsRating rating;
      if (r == 0) {
        final pick = rng.nextDouble();
        rating = pick < 0.15
            ? FsrsRating.hard
            : pick < 0.85
            ? FsrsRating.good
            : FsrsRating.easy;
      } else {
        final recallProb = trueScheduler.retrievability(trueCard, now);
        if (rng.nextDouble() < recallProb) {
          final pick = rng.nextDouble();
          rating = pick < 0.15
              ? FsrsRating.hard
              : pick < 0.85
              ? FsrsRating.good
              : FsrsRating.easy;
        } else {
          rating = FsrsRating.again;
        }
      }

      logs.add(
        PracticeReviewLog(
          cardKey: key,
          rating: rating,
          elapsedDays: elapsed,
          state: r == 0 ? FsrsState.newCard : FsrsState.review,
          reviewedAt: now,
        ),
      );

      trueCard = trueScheduler.review(trueCard, rating, now);
      scheduledCard = defaultScheduler.review(scheduledCard, rating, now);
      final intervalDays = math.max(
        1,
        scheduledCard.due.difference(now).inDays,
      );
      // Add slight deterministic schedule jitter (0.7x..1.5x) for richness.
      final actualDays = math.max(
        1,
        (intervalDays * (0.7 + rng.nextDouble() * 0.8)).round(),
      );
      now = now.add(Duration(days: actualDays));
    }
  }
  return logs;
}

void _expectValidBounds(List<double> weights) {
  expect(weights, hasLength(FsrsScheduler.defaultWeights.length));
  for (var i = 0; i < weights.length; i++) {
    expect(weights[i].isFinite, isTrue, reason: 'w[$i] must be finite');
    expect(
      weights[i],
      inInclusiveRange(FsrsOptimizer.minBounds[i], FsrsOptimizer.maxBounds[i]),
      reason: 'w[$i]=${weights[i]} out of safe bounds',
    );
  }
  // Initial stabilities remain monotonic.
  expect(weights[0], lessThanOrEqualTo(weights[1]));
  expect(weights[1], lessThanOrEqualTo(weights[2]));
  expect(weights[2], lessThanOrEqualTo(weights[3]));
}

void main() {
  group(FsrsOptimizer, () {
    const optimizer = FsrsOptimizer();

    test('default weights lie strictly inside safe optimizer bounds', () {
      _expectValidBounds(FsrsScheduler.defaultWeights);
    });

    test('refuses to optimize with fewer than minReviews evaluable logs', () {
      final empty = optimizer.optimize(const []);
      expect(empty.weights, FsrsScheduler.defaultWeights);
      expect(empty.initialLoss, 0);
      expect(empty.optimizedLoss, 0);
      expect(empty.reviewCount, 0);
      expect(empty.improved, isFalse);
      expect(empty.hasEnoughReviews, isFalse);
      expect(empty.relativeImprovement, 0);

      // 60 first-time card reviews have 0 multi-review recall observations.
      final firstOnly = [
        for (var i = 0; i < 60; i++)
          PracticeReviewLog(
            cardKey: 'c:$i#r',
            rating: FsrsRating.good,
            elapsedDays: 0,
            state: FsrsState.newCard,
            reviewedAt: DateTime.utc(2026, 1, 1, i),
          ),
      ];
      expect(FsrsOptimizer.countEvaluableReviews(firstOnly), 0);
      final singleResult = optimizer.optimize(firstOnly);
      expect(singleResult.improved, isFalse);
      expect(singleResult.hasEnoughReviews, isFalse);
      expect(singleResult.weights, FsrsScheduler.defaultWeights);

      // 49 evaluable reviews is still below minReviews (50).
      final tooFew = _syntheticLogs(
        trueWeights: FsrsScheduler.defaultWeights,
        cardCount: 7,
        reviewsPerCard: 8, // 7 * 7 = 49 evaluable
      );
      expect(FsrsOptimizer.countEvaluableReviews(tooFew), 49);
      final fewResult = optimizer.optimize(tooFew);
      expect(fewResult.reviewCount, 49);
      expect(fewResult.improved, isFalse);
      expect(fewResult.hasEnoughReviews, isFalse);
      expect(fewResult.weights, FsrsScheduler.defaultWeights);
    });

    test('improves log-loss for a faster-forgetting learner', () {
      // Learner forgets much faster than FSRS defaults.
      final fastForgetWeights = [...FsrsScheduler.defaultWeights]
        ..[0] = 0.2
        ..[1] = 0.4
        ..[2] = 0.8
        ..[3] = 2.0
        ..[8] = 0.7;
      final logs = _syntheticLogs(
        trueWeights: fastForgetWeights,
        cardCount: 40,
        reviewsPerCard: 6, // 200 evaluable reviews
      );
      final result = optimizer.optimize(logs);
      expect(result.hasEnoughReviews, isTrue);
      expect(result.reviewCount, 200);
      expect(result.improved, isTrue);
      expect(result.optimizedLoss, lessThan(result.initialLoss));
      expect(result.relativeImprovement, greaterThan(0.02));
      _expectValidBounds(result.weights);
      // Fitted weights should lower initial Good stability compared to default.
      expect(result.weights[2], lessThan(FsrsScheduler.defaultWeights[2]));
      // Verified loss matches evaluateLoss directly.
      expect(
        optimizer.evaluateLoss(logs, result.weights),
        closeTo(result.optimizedLoss, 1e-12),
      );
    });

    test('improves log-loss for a stronger-retention learner', () {
      // Learner retains cards much longer than FSRS defaults.
      final strongRetentionWeights = [...FsrsScheduler.defaultWeights]
        ..[0] = 1.5
        ..[1] = 4.0
        ..[2] = 10.0
        ..[3] = 30.0
        ..[8] = 2.4;
      final logs = _syntheticLogs(
        trueWeights: strongRetentionWeights,
        cardCount: 40,
        reviewsPerCard: 6,
        seed: 99,
      );
      final result = optimizer.optimize(logs);
      expect(result.hasEnoughReviews, isTrue);
      expect(result.improved, isTrue);
      expect(result.optimizedLoss, lessThan(result.initialLoss));
      _expectValidBounds(result.weights);
    });

    test('is deterministic regardless of input log ordering', () {
      final shifted = [...FsrsScheduler.defaultWeights]
        ..[2] = 0.9
        ..[8] = 0.8;
      final logs = _syntheticLogs(
        trueWeights: shifted,
        cardCount: 30,
        reviewsPerCard: 5,
        seed: 7,
      );
      final reversed = logs.reversed.toList();
      final a = optimizer.optimize(logs);
      final b = optimizer.optimize(reversed);
      expect(a, b);
    });

    test('handles same-day learning steps alongside multi-day reviews', () {
      final base = DateTime.utc(2026, 3, 1, 9);
      final logs = <PracticeReviewLog>[];
      for (var c = 0; c < 30; c++) {
        final key = 'learn:$c#r';
        final t0 = base.add(Duration(days: c));
        // Same-day learning steps (not scored, but replayed for short-term S).
        logs
          ..add(
            PracticeReviewLog(
              cardKey: key,
              rating: FsrsRating.good,
              elapsedDays: 0,
              state: FsrsState.newCard,
              reviewedAt: t0,
            ),
          )
          ..add(
            PracticeReviewLog(
              cardKey: key,
              rating: FsrsRating.good,
              elapsedDays: 10 / 1440,
              state: FsrsState.learning,
              reviewedAt: t0.add(const Duration(minutes: 10)),
            ),
          )
          // Multi-day reviews (scored).
          ..add(
            PracticeReviewLog(
              cardKey: key,
              rating: c.isEven ? FsrsRating.again : FsrsRating.good,
              elapsedDays: 5,
              state: FsrsState.review,
              reviewedAt: t0.add(const Duration(days: 5)),
            ),
          )
          ..add(
            PracticeReviewLog(
              cardKey: key,
              rating: c % 3 == 0 ? FsrsRating.again : FsrsRating.good,
              elapsedDays: 10,
              state: FsrsState.review,
              reviewedAt: t0.add(const Duration(days: 15)),
            ),
          );
      }
      expect(FsrsOptimizer.countEvaluableReviews(logs), 60);
      final result = optimizer.optimize(logs);
      expect(result.hasEnoughReviews, isTrue);
      expect(result.reviewCount, 60);
      _expectValidBounds(result.weights);
    });

    test('optimizes 1,000 logs within 200 ms', () {
      final shifted = [...FsrsScheduler.defaultWeights]
        ..[2] = 1.0
        ..[8] = 0.9;
      final logs = _syntheticLogs(
        trueWeights: shifted,
        cardCount: 200,
        reviewsPerCard: 5, // 1,000 logs, 800 evaluable
        seed: 123,
      );
      expect(logs, hasLength(1000));
      // Warm up JIT once on a small subset.
      optimizer.optimize(logs.take(100).toList());

      final sw = Stopwatch()..start();
      final result = optimizer.optimize(logs);
      sw.stop();

      expect(result.improved, isTrue);
      expect(result.optimizedLoss, lessThan(result.initialLoss));
      _expectValidBounds(result.weights);
      expect(
        sw.elapsedMilliseconds,
        lessThan(200),
        reason: 'Took ${sw.elapsedMilliseconds} ms for 1,000 logs',
      );
    });
  });
}
