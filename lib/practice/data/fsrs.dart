// FSRS-5 spaced-repetition scheduler, in pure Dart.
//
// Source: the Free Spaced Repetition Scheduler (FSRS) by Jarrett Ye and the
// Open Spaced Repetition project, the algorithm Anki uses since 23.10
// (https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm).
// This file follows the reference implementation py-fsrs v5.1.3
// (https://github.com/open-spaced-repetition/py-fsrs, MIT License,
// Copyright (c) 2022 Open Spaced Repetition): its 19 default weights, the
// learning and relearning steps, the short-term stability of same-day
// reviews and the interval fuzz. Its tests' published sequences are the
// golden values of test/practice/data/fsrs_test.dart. No GPL code was used.

import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Where a card is in its life ([FsrsCard.state]).
enum FsrsState {
  /// Never reviewed.
  newCard('new'),

  /// Seen, still in the short learning steps (minutes).
  learning('learning'),

  /// Learned: scheduled in days by its stability.
  review('review'),

  /// Forgotten during review, back in the short relearning steps.
  relearning('relearning');

  new(this.key);

  /// How the state is stored.
  final String key;

  /// The state stored as [key]; null for an unknown one.
  static FsrsState? fromKey(Object? key) {
    for (final state in values) {
      if (state.key == key) return state;
    }
    return null;
  }
}

/// How well the answer was remembered.
enum FsrsRating {
  /// Forgotten.
  again(1),

  /// Remembered with serious difficulty.
  hard(2),

  /// Remembered after a moment.
  good(3),

  /// Remembered at once.
  easy(4);

  new(this.grade);

  /// FSRS's grade, 1 to 4 (also the keyboard shortcut).
  final int grade;

  /// The rating of [grade]; null outside 1 to 4.
  static FsrsRating? fromGrade(Object? grade) {
    for (final rating in values) {
      if (rating.grade == grade) return rating;
    }
    return null;
  }
}

/// The memory state of one card: what FSRS needs to schedule it.
final class FsrsCard extends Equatable {
  const new({
    required this.due,
    this.state = FsrsState.newCard,
    this.step,
    this.stability,
    this.difficulty,
    this.lastReview,
  });

  /// A card never reviewed, due at [now].
  new fresh(DateTime now) : this(due: now.toUtc());

  /// Reads [toJson]'s output; throws [FormatException] when it is not one.
  factory fromJson(Map<String, Object?> json) {
    final state = FsrsState.fromKey(json['state']);
    final due = _date(json['due']);
    if (state == null || due == null) {
      throw const FormatException('Not an FSRS card');
    }
    return FsrsCard(
      state: state,
      step: (json['step'] as num?)?.toInt(),
      stability: (json['stability'] as num?)?.toDouble(),
      difficulty: (json['difficulty'] as num?)?.toDouble(),
      due: due,
      lastReview: _date(json['lastReview']),
    );
  }

  final FsrsState state;

  /// The learning or relearning step the card is at; null in review.
  final int? step;

  /// Days after which the probability of recall falls to 90 %; null
  /// before the first review.
  final double? stability;

  /// 1 (easy) to 10 (hard); null before the first review.
  final double? difficulty;

  /// When the card is next due.
  final DateTime due;
  final DateTime? lastReview;

  /// Whether the card was never reviewed.
  bool get isNew => state == FsrsState.newCard;

  Map<String, Object?> toJson() => {
    'state': state.key,
    if (step != null) 'step': step,
    if (stability != null) 'stability': stability,
    if (difficulty != null) 'difficulty': difficulty,
    'due': due.toUtc().toIso8601String(),
    if (lastReview != null) 'lastReview': lastReview!.toUtc().toIso8601String(),
  };

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;

  @override
  List<Object?> get props => [
    state,
    step,
    stability,
    difficulty,
    due,
    lastReview,
  ];
}

/// The FSRS-5 scheduler (see the file's header for the source).
///
/// * A new card goes through [learningSteps] (minutes): Again starts them
///   over, Hard repeats the step (the first one: halfway to the second),
///   Good moves on and Easy graduates at once. After the last step, the
///   card is in review, scheduled in whole days by its stability for the
///   [desiredRetention] (the probability of recalling it when it is due).
/// * Again in review goes through [relearningSteps], then back to review.
/// * Intervals are at least 1 day and at most [maximumInterval] days;
///   from 3 days on they get a little random [fuzz] (as in Anki), so cards
///   learned together do not stay due together.
/// * Reviews on the day of the last one change the stability by the
///   short-term formula (weights 17 and 18).
class FsrsScheduler {
  new({
    List<double> weights = defaultWeights,
    double desiredRetention = defaultDesiredRetention,
    this.learningSteps = const [Duration(minutes: 1), Duration(minutes: 10)],
    this.relearningSteps = const [Duration(minutes: 10)],
    this.maximumInterval = defaultMaximumInterval,
    this.fuzz = true,
  }) : weights = List.unmodifiable(weights),
       desiredRetention = desiredRetention.clamp(
         minDesiredRetention,
         maxDesiredRetention,
       ) {
    if (weights.length != defaultWeights.length) {
      throw ArgumentError.value(weights.length, 'weights', 'must be 19');
    }
    if (maximumInterval < 1) {
      throw ArgumentError.value(maximumInterval, 'maximumInterval');
    }
  }

  /// FSRS-5's default weights (py-fsrs v5 `DEFAULT_PARAMETERS`).
  static const defaultWeights = [
    0.40255,
    1.18385,
    3.173,
    15.69105,
    7.1949,
    0.5345,
    1.4604,
    0.0046,
    1.54575,
    0.1192,
    1.01925,
    1.9395,
    0.11,
    0.29605,
    2.2698,
    0.2315,
    2.9898,
    0.51655,
    0.6621,
  ];

  static const defaultDesiredRetention = 0.9;

  /// The range [desiredRetention] is kept in (Anki allows 0.7 to 0.99;
  /// above 0.97 the workload explodes).
  static const minDesiredRetention = 0.7;
  static const maxDesiredRetention = 0.97;

  /// 100 years, as in Anki and py-fsrs.
  static const defaultMaximumInterval = 36500;

  /// The forgetting curve's decay and factor (FSRS-5): R(t) = (1 +
  /// [factor] · t / S) ^ [decay], so R(S) = 0.9.
  static const decay = -0.5;
  static final double factor = math.pow(0.9, 1 / decay) - 1;

  final List<double> weights;
  final double desiredRetention;
  final List<Duration> learningSteps;
  final List<Duration> relearningSteps;

  /// The longest interval, in days.
  final int maximumInterval;

  /// Whether intervals of 3 days and more get a little randomness.
  final bool fuzz;

  /// The probability of recalling [card] at [now] (0 for a new card).
  double retrievability(FsrsCard card, DateTime now) {
    final last = card.lastReview;
    final stability = card.stability;
    if (last == null || stability == null) return 0;
    final days = math.max(0, _wholeDays(now.difference(last)));
    return _retrievability(days.toDouble(), stability);
  }

  double _retrievability(double days, double stability) =>
      math.pow(1 + factor * days / stability, decay).toDouble();

  /// The card after rating it [rating] at [now]. [random] draws the
  /// fuzz (default: a new [math.Random]).
  FsrsCard review(
    FsrsCard card,
    FsrsRating rating,
    DateTime now, {
    math.Random? random,
  }) {
    // Times are kept in UTC (stored as such, and equal after a round trip).
    final at = now.toUtc();
    final last = card.lastReview;
    final days = last == null ? null : _wholeDays(at.difference(last));
    final first = card.stability == null || card.difficulty == null;
    double stability;
    double difficulty;
    if (first) {
      stability = _initialStability(rating);
      difficulty = _initialDifficulty(rating);
    } else if (days != null && days < 1) {
      stability = _shortTermStability(card.stability!, rating);
      difficulty = _nextDifficulty(card.difficulty!, rating);
    } else {
      stability = _nextStability(
        card.difficulty!,
        card.stability!,
        retrievability(card, at),
        rating,
      );
      difficulty = _nextDifficulty(card.difficulty!, rating);
    }

    final (state, step, interval) = switch (card.state) {
      FsrsState.newCard || FsrsState.learning => _stepped(
        learningSteps,
        card.state == FsrsState.newCard ? 0 : card.step ?? 0,
        rating,
        stability,
        again: FsrsState.learning,
      ),
      FsrsState.review => _reviewed(rating, stability),
      FsrsState.relearning => _stepped(
        relearningSteps,
        card.step ?? 0,
        rating,
        stability,
        again: FsrsState.relearning,
      ),
    };
    final next = state == FsrsState.review && fuzz
        ? _fuzzed(interval, random ?? math.Random())
        : interval;
    return FsrsCard(
      state: state,
      step: step,
      stability: stability,
      difficulty: difficulty,
      due: at.add(next),
      lastReview: at,
    );
  }

  /// What each rating would do to [card] at [now], with the fuzz drawn
  /// from a generator seeded with [seed]: the same [seed] gives the same
  /// intervals, so the interval shown on a button is the one applied.
  Map<FsrsRating, FsrsCard> preview(
    FsrsCard card,
    DateTime now, {
    required int seed,
  }) => {
    for (final rating in FsrsRating.values)
      rating: review(card, rating, now, random: math.Random(seed)),
  };

  /// A learning or relearning step: state, step and interval.
  (FsrsState, int?, Duration) _stepped(
    List<Duration> steps,
    int step,
    FsrsRating rating,
    double stability, {
    required FsrsState again,
  }) {
    (FsrsState, int?, Duration) graduate() =>
        (FsrsState.review, null, _days(stability));
    // Also a card left at a step a scheduler with more steps gave it.
    if (steps.isEmpty || (step >= steps.length && rating != FsrsRating.again)) {
      return graduate();
    }
    return switch (rating) {
      FsrsRating.again => (again, 0, steps.first),
      FsrsRating.hard => (
        again,
        step,
        step == 0 && steps.length == 1
            ? steps.first * 1.5
            : step == 0
            ? (steps[0] + steps[1]) ~/ 2
            : steps[step],
      ),
      FsrsRating.good =>
        step + 1 >= steps.length
            ? graduate()
            : (again, step + 1, steps[step + 1]),
      FsrsRating.easy => graduate(),
    };
  }

  (FsrsState, int?, Duration) _reviewed(FsrsRating rating, double stability) {
    if (rating == FsrsRating.again && relearningSteps.isNotEmpty) {
      return (FsrsState.relearning, 0, relearningSteps.first);
    }
    return (FsrsState.review, null, _days(stability));
  }

  Duration _days(double stability) => Duration(days: intervalDays(stability));

  /// The interval in whole days for [stability] at the [desiredRetention]:
  /// at least 1, at most [maximumInterval].
  int intervalDays(double stability) {
    final days =
        stability / factor * (math.pow(desiredRetention, 1 / decay) - 1);
    return roundHalfEven(days).clamp(1, maximumInterval);
  }

  double _initialStability(FsrsRating rating) =>
      math.max(weights[rating.grade - 1], 0.1);

  double _initialDifficulty(FsrsRating rating) => _clampDifficulty(
    weights[4] - math.exp(weights[5] * (rating.grade - 1)) + 1,
  );

  double _shortTermStability(double stability, FsrsRating rating) =>
      stability * math.exp(weights[17] * (rating.grade - 3 + weights[18]));

  double _nextDifficulty(double difficulty, FsrsRating rating) {
    final delta = -(weights[6] * (rating.grade - 3));
    final damped = difficulty + (10 - difficulty) * delta / 9;
    final easy = _initialDifficulty(FsrsRating.easy);
    return _clampDifficulty(weights[7] * easy + (1 - weights[7]) * damped);
  }

  double _nextStability(
    double difficulty,
    double stability,
    double retrievability,
    FsrsRating rating,
  ) {
    if (rating == FsrsRating.again) {
      final longTerm =
          weights[11] *
          math.pow(difficulty, -weights[12]) *
          (math.pow(stability + 1, weights[13]) - 1) *
          math.exp((1 - retrievability) * weights[14]);
      final shortTerm = stability / math.exp(weights[17] * weights[18]);
      return math.min(longTerm, shortTerm);
    }
    final hardPenalty = rating == FsrsRating.hard ? weights[15] : 1.0;
    final easyBonus = rating == FsrsRating.easy ? weights[16] : 1.0;
    return stability *
        (1 +
            math.exp(weights[8]) *
                (11 - difficulty) *
                math.pow(stability, -weights[9]) *
                (math.exp((1 - retrievability) * weights[10]) - 1) *
                hardPenalty *
                easyBonus);
  }

  static double _clampDifficulty(double difficulty) =>
      difficulty.clamp(1, 10).toDouble();

  /// The fuzz ranges of py-fsrs: ±15 % of the days from 2.5 to 7, ±10 %
  /// from 7 to 20 and ±5 % beyond, plus one day.
  static const _fuzzRanges = [(2.5, 7.0, 0.15), (7.0, 20.0, 0.1)];
  static const _lastFuzzRange = (20.0, 0.05);

  /// The lowest and highest fuzzed interval for [days] (at least 2).
  (int, int) fuzzRange(int days) {
    var delta = 1.0;
    for (final (start, end, share) in _fuzzRanges) {
      delta += share * math.max(math.min(days.toDouble(), end) - start, 0);
    }
    final (start, share) = _lastFuzzRange;
    delta += share * math.max(days - start, 0);
    final high = math.min(roundHalfEven(days + delta), maximumInterval);
    final low = math.min(math.max(2, roundHalfEven(days - delta)), high);
    return (low, high);
  }

  /// [interval] with fuzz: a random whole number of days in [fuzzRange]
  /// (py-fsrs rounds the draw, which can reach one day past the range;
  /// this floors it, as ts-fsrs does). Intervals under 2.5 days stay.
  Duration _fuzzed(Duration interval, math.Random random) {
    final days = _wholeDays(interval);
    if (days < 2.5) return interval;
    final (low, high) = fuzzRange(days);
    final fuzzed = (random.nextDouble() * (high - low + 1) + low).floor();
    return Duration(days: math.min(fuzzed, maximumInterval));
  }

  /// Whole days of [duration], rounded down (Python's `timedelta.days`).
  static int _wholeDays(Duration duration) {
    final micros = duration.inMicroseconds;
    const perDay = Duration.microsecondsPerDay;
    return micros >= 0 ? micros ~/ perDay : -((-micros + perDay - 1) ~/ perDay);
  }

  /// [value] rounded to the nearest integer, ties to even (Python's
  /// `round`, which the reference implementation uses).
  @visibleForTesting
  static int roundHalfEven(num value) {
    final floor = value.floor();
    final fraction = value - floor;
    if (fraction > 0.5) return floor + 1;
    if (fraction < 0.5) return floor;
    return floor.isEven ? floor : floor + 1;
  }
}
