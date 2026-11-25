import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/models/practice_review_log.dart';

/// Top-level entry point for running [FsrsOptimizer.optimize] in a background
/// isolate via [compute].
FsrsOptimizationResult runFsrsOptimization(List<PracticeReviewLog> logs) =>
    const FsrsOptimizer().optimize(logs);

/// Runs [FsrsOptimizer.optimize] off the UI thread so large review histories
/// never freeze the practice overview or its loading indicator.
Future<FsrsOptimizationResult> optimizeFsrsInBackground(
  List<PracticeReviewLog> logs,
) => compute(runFsrsOptimization, logs);

/// The outcome of fitting personalized FSRS-5 weights to a user's review logs.
final class FsrsOptimizationResult extends Equatable {
  new({
    required List<double> weights,
    required this.initialLoss,
    required this.optimizedLoss,
    required this.reviewCount,
    required this.improved,
  }) : weights = List.unmodifiable(weights);

  /// The 19 FSRS-5 weights (equal to [FsrsScheduler.defaultWeights] when not
  /// [improved]).
  final List<double> weights;

  /// Binary cross-entropy log-loss under [FsrsScheduler.defaultWeights].
  final double initialLoss;

  /// Binary cross-entropy log-loss under [weights].
  final double optimizedLoss;

  /// How many recall observations were evaluated.
  final int reviewCount;

  /// Whether [weights] measurably improved log-loss over the defaults.
  final bool improved;

  /// Whether there were at least [FsrsOptimizer.minReviews] evaluable reviews.
  bool get hasEnoughReviews => reviewCount >= FsrsOptimizer.minReviews;

  /// Relative reduction in log-loss (`0` when not improved).
  double get relativeImprovement => improved && initialLoss > 0
      ? ((initialLoss - optimizedLoss) / initialLoss).clamp(0.0, 1.0)
      : 0;

  @override
  List<Object?> get props => [
    weights,
    initialLoss,
    optimizedLoss,
    reviewCount,
    improved,
  ];
}

/// Pure-Dart FSRS-5 weight optimizer.
///
/// Groups [PracticeReviewLog]s by card, replays each card's review sequence
/// through [FsrsScheduler] (without fuzz) to compute binary cross-entropy
/// log-loss over recall outcomes (`rating != FsrsRating.again` -> 1,
/// `FsrsRating.again` -> 0), and runs deterministic bounded normalized gradient
/// descent with L2 regularization toward [FsrsScheduler.defaultWeights].
class FsrsOptimizer {
  const new({
    this.l2Strength = defaultL2Strength,
    this.maxIterations = defaultMaxIterations,
  });

  /// Minimum evaluable multi-review / review-state observations required to
  /// fit personalized weights.
  static const int minReviews = 50;

  /// Default L2 regularization weight (in scale-normalized parameter space)
  /// pulling fitted weights toward [FsrsScheduler.defaultWeights].
  static const double defaultL2Strength = 0.004;

  /// Default maximum optimization iterations.
  static const int defaultMaxIterations = 24;

  /// Minimum safe FSRS-5 bounds for the 19 weights.
  static const List<double> minBounds = [
    0.1, // w0: initial stability (Again)
    0.1, // w1: initial stability (Hard)
    0.1, // w2: initial stability (Good)
    0.1, // w3: initial stability (Easy)
    1.0, // w4: initial difficulty intercept
    0.001, // w5: initial difficulty slope
    0.001, // w6: difficulty delta
    0.001, // w7: difficulty mean reversion
    0.0, // w8: recall stability factor
    0.0, // w9: stability power decay
    0.001, // w10: retrievability sensitivity (recall)
    0.001, // w11: lapse stability multiplier
    0.001, // w12: lapse difficulty exponent
    0.001, // w13: lapse stability exponent
    0.0, // w14: lapse retrievability exponent
    0.0, // w15: hard penalty
    1.0, // w16: easy bonus
    0.0, // w17: short-term stability factor
    0.0, // w18: short-term stability offset
  ];

  /// Maximum safe FSRS-5 bounds for the 19 weights.
  static const List<double> maxBounds = [
    100.0, // w0
    100.0, // w1
    100.0, // w2
    100.0, // w3
    10.0, // w4
    4.0, // w5
    4.0, // w6
    0.75, // w7
    4.5, // w8
    0.8, // w9
    3.5, // w10
    5.0, // w11
    0.25, // w12
    0.9, // w13
    4.0, // w14
    1.0, // w15
    6.0, // w16
    2.0, // w17
    2.0, // w18
  ];

  /// Natural step / regularization scales for each parameter so all 19
  /// coordinates move at comparable magnitude.
  static const List<double> _scales = [
    0.5, // w0
    1.0, // w1
    2.5, // w2
    8.0, // w3
    2.0, // w4
    0.5, // w5
    1.0, // w6
    0.15, // w7
    1.0, // w8
    0.2, // w9
    0.8, // w10
    1.0, // w11
    0.08, // w12
    0.25, // w13
    1.0, // w14
    0.25, // w15
    1.0, // w16
    0.4, // w17
    0.4, // w18
  ];

  static const double _probEps = 1e-7;
  static const double _minImprovement = 1e-4;
  static const double _fdEps = 1e-4;

  final double l2Strength;
  final int maxIterations;

  /// How many evaluable recall observations [logs] contains.
  static int countEvaluableReviews(List<PracticeReviewLog> logs) {
    final sequences = _buildSequences(logs);
    var count = 0;
    for (final seq in sequences) {
      for (final step in seq) {
        if (step.scored) count++;
      }
    }
    return count;
  }

  /// Evaluates the unregularized mean binary cross-entropy log-loss of
  /// [weights] over [logs] by replaying each card's sequence through
  /// [FsrsScheduler]. Returns `0` when there are no evaluable observations.
  double evaluateLoss(List<PracticeReviewLog> logs, List<double> weights) {
    final sequences = _buildSequences(logs);
    return _evaluateWithScheduler(sequences, weights).loss;
  }

  /// Fits personalized FSRS-5 weights from [logs].
  ///
  /// Requires at least [minReviews] evaluable multi-review / review-state
  /// observations; otherwise returns [FsrsScheduler.defaultWeights] with
  /// `improved: false`.
  FsrsOptimizationResult optimize(List<PracticeReviewLog> logs) {
    final sequences = _buildSequences(logs);
    final baseline = _evaluateWithScheduler(
      sequences,
      FsrsScheduler.defaultWeights,
    );
    final reviewCount = baseline.count;
    final initialLoss = baseline.loss;

    if (reviewCount < minReviews) {
      return FsrsOptimizationResult(
        weights: FsrsScheduler.defaultWeights,
        initialLoss: initialLoss,
        optimizedLoss: initialLoss,
        reviewCount: reviewCount,
        improved: false,
      );
    }

    final activeParams = _activeParameters(sequences);
    final w = List<double>.of(FsrsScheduler.defaultWeights);
    final candidate = List<double>.of(w);
    final grad = List<double>.filled(w.length, 0);

    var currentObj = _objective(sequences, w, reviewCount);
    var bestObj = currentObj;
    var bestWeights = List<double>.of(w);
    var stepSize = 0.25;

    for (var iter = 0; iter < maxIterations; iter++) {
      // Compute scale-normalized finite-difference gradient over active params.
      var gradNormSq = 0.0;
      for (var k = 0; k < w.length; k++) {
        grad[k] = 0;
      }
      for (final k in activeParams) {
        final orig = w[k];
        final delta = _fdEps * _scales[k];
        final up = math.min(maxBounds[k], orig + delta);
        final down = math.max(minBounds[k], orig - delta);
        final span = up - down;
        if (span <= 0) continue;

        double g;
        if (up - orig >= delta * 0.5 && orig - down >= delta * 0.5) {
          // Forward difference from currentObj is 2x faster and accurate
          // enough for backtracking descent with L2 regularization.
          w[k] = up;
          final fUp = _objective(sequences, w, reviewCount);
          g = (fUp - currentObj) / (up - orig);
        } else if (up > orig) {
          w[k] = up;
          final fUp = _objective(sequences, w, reviewCount);
          g = (fUp - currentObj) / (up - orig);
        } else {
          w[k] = down;
          final fDown = _objective(sequences, w, reviewCount);
          g = (currentObj - fDown) / (orig - down);
        }
        w[k] = orig;

        final scaledG = g * _scales[k];
        if (scaledG.isFinite) {
          grad[k] = scaledG;
          gradNormSq += scaledG * scaledG;
        }
      }

      if (gradNormSq < 1e-12) break;
      final gradNorm = math.sqrt(gradNormSq);

      // Backtracking line search along the normalized steepest-descent step.
      var accepted = false;
      var alpha = stepSize;
      for (var ls = 0; ls < 8; ls++) {
        for (var k = 0; k < w.length; k++) {
          candidate[k] = w[k] - alpha * (grad[k] / gradNorm) * _scales[k];
        }
        _project(candidate);
        final candObj = _objective(sequences, candidate, reviewCount);
        if (candObj + 1e-7 < currentObj) {
          final improvement = currentObj - candObj;
          for (var k = 0; k < w.length; k++) {
            w[k] = candidate[k];
          }
          currentObj = candObj;
          if (candObj < bestObj) {
            bestObj = candObj;
            bestWeights = List<double>.of(w);
          }
          // Slightly grow step size on acceptance for faster convergence.
          stepSize = math.min(0.6, alpha * 1.25);
          accepted = true;
          if (improvement < 1e-5) {
            iter = maxIterations; // Converged.
          }
          break;
        }
        alpha *= 0.5;
      }

      if (!accepted) break;
    }

    // Verify final unregularized log-loss directly through FsrsScheduler.
    final verified = _evaluateWithScheduler(sequences, bestWeights);
    final optimizedLoss = verified.loss;
    final improved =
        optimizedLoss.isFinite && optimizedLoss + _minImprovement < initialLoss;

    if (!improved) {
      return FsrsOptimizationResult(
        weights: FsrsScheduler.defaultWeights,
        initialLoss: initialLoss,
        optimizedLoss: initialLoss,
        reviewCount: reviewCount,
        improved: false,
      );
    }

    return FsrsOptimizationResult(
      weights: bestWeights,
      initialLoss: initialLoss,
      optimizedLoss: optimizedLoss,
      reviewCount: reviewCount,
      improved: true,
    );
  }

  /// Evaluates mean log-loss + L2 penalty using zero-allocation scalar FSRS-5
  /// replay (mathematically identical to [FsrsScheduler] with `fuzz: false`).
  double _objective(
    List<List<_ReplayStep>> sequences,
    List<double> w,
    int reviewCount,
  ) {
    const decay = FsrsScheduler.decay;
    final factor = FsrsScheduler.factor;
    final d0Easy = (w[4] - math.exp(w[5] * 3) + 1).clamp(1.0, 10.0);

    var lossSum = 0.0;
    for (final seq in sequences) {
      double? s;
      double? d;
      for (final step in seq) {
        final grade = step.grade;
        if (s == null || d == null) {
          s = math.max(w[grade - 1], 0.1);
          d = (w[4] - math.exp(w[5] * (grade - 1)) + 1).clamp(1.0, 10.0);
          continue;
        }

        if (step.scored) {
          final r = math.pow(1 + factor * step.scoreDays / s, decay).toDouble();
          final p = r.clamp(_probEps, 1.0 - _probEps);
          lossSum -= step.recalled ? math.log(p) : math.log(1.0 - p);
        }

        if (step.wholeDays < 1) {
          s = s * math.exp(w[17] * (grade - 3 + w[18]));
        } else {
          final r = math.pow(1 + factor * step.wholeDays / s, decay).toDouble();
          if (grade == 1) {
            final longTerm =
                w[11] *
                math.pow(d, -w[12]) *
                (math.pow(s + 1, w[13]) - 1) *
                math.exp((1 - r) * w[14]);
            final shortTerm = s / math.exp(w[17] * w[18]);
            s = math.min(longTerm, shortTerm);
          } else {
            final hardPenalty = grade == 2 ? w[15] : 1.0;
            final easyBonus = grade == 4 ? w[16] : 1.0;
            s =
                s *
                (1 +
                    math.exp(w[8]) *
                        (11 - d) *
                        math.pow(s, -w[9]) *
                        (math.exp((1 - r) * w[10]) - 1) *
                        hardPenalty *
                        easyBonus);
          }
        }
        // Guard against numerical collapse during extreme trial steps.
        if (!s.isFinite || s < 0.01) s = 0.01;
        final delta = -(w[6] * (grade - 3));
        final damped = d + (10 - d) * delta / 9;
        d = (w[7] * d0Easy + (1 - w[7]) * damped).clamp(1.0, 10.0);
      }
    }

    var reg = 0.0;
    if (l2Strength > 0) {
      const defaults = FsrsScheduler.defaultWeights;
      for (var k = 0; k < w.length; k++) {
        final diff = (w[k] - defaults[k]) / _scales[k];
        reg += diff * diff;
      }
      reg *= l2Strength;
    }

    return lossSum / reviewCount + reg;
  }

  /// Replays [sequences] directly through [FsrsScheduler] (no fuzz) to compute
  /// exact binary cross-entropy log-loss.
  ({double loss, int count}) _evaluateWithScheduler(
    List<List<_ReplayStep>> sequences,
    List<double> weights,
  ) {
    final scheduler = FsrsScheduler(weights: weights, fuzz: false);
    var lossSum = 0.0;
    var count = 0;

    for (final seq in sequences) {
      var card = FsrsCard.fresh(seq.first.reviewedAt);
      for (final step in seq) {
        if (step.scored) {
          final double r;
          if (step.wholeDays >= 1) {
            r = scheduler.retrievability(card, step.reviewedAt);
          } else {
            final stability = card.stability ?? 0.1;
            r = math
                .pow(
                  1 + FsrsScheduler.factor * step.scoreDays / stability,
                  FsrsScheduler.decay,
                )
                .toDouble();
          }
          final p = r.clamp(_probEps, 1.0 - _probEps);
          lossSum -= step.recalled ? math.log(p) : math.log(1.0 - p);
          count++;
        }
        card = scheduler.review(card, step.rating, step.reviewedAt);
      }
    }

    return (loss: count == 0 ? 0.0 : lossSum / count, count: count);
  }

  /// Projects [w] into [minBounds]..[maxBounds] and keeps initial stabilities
  /// monotonic (`w[0] <= w[1] <= w[2] <= w[3]`).
  static void _project(List<double> w) {
    for (var k = 0; k < w.length; k++) {
      final v = w[k];
      w[k] = v.isFinite
          ? v.clamp(minBounds[k], maxBounds[k])
          : FsrsScheduler.defaultWeights[k];
    }
    for (var k = 1; k <= 3; k++) {
      if (w[k] < w[k - 1]) w[k] = w[k - 1];
    }
  }

  /// Determines which of the 19 weights actually participate in [sequences],
  /// skipping gradient evaluations for inactive parameters.
  static List<int> _activeParameters(List<List<_ReplayStep>> sequences) {
    final active = List<bool>.filled(19, false);
    for (final seq in sequences) {
      if (seq.length < 2) continue;
      // Only sequences with at least one scored observation affect loss.
      if (!seq.any((step) => step.scored)) continue;
      active[seq.first.grade - 1] = true;
      for (var i = 1; i < seq.length; i++) {
        final prev = seq[i - 1];
        final step = seq[i];
        // Everything that influences S/D before a scored step matters.
        if (i == 1) {
          // w4, w5 set initial difficulty used in subsequent updates.
          if (seq.length > 2 || step.wholeDays >= 1) {
            active[4] = true;
            active[5] = true;
          }
        }
        if (step.wholeDays < 1) {
          active[17] = true;
          active[18] = true;
        } else {
          active[4] = true;
          active[5] = true;
          active[6] = true;
          active[7] = true;
          if (prev.grade == 1) {
            active[11] = true;
            active[12] = true;
            active[13] = true;
            active[14] = true;
            active[17] = true;
            active[18] = true;
          } else {
            active[8] = true;
            active[9] = true;
            active[10] = true;
            if (prev.grade == 2) active[15] = true;
            if (prev.grade == 4) active[16] = true;
          }
        }
      }
    }
    return [
      for (var k = 0; k < active.length; k++)
        if (active[k]) k,
    ];
  }

  /// Groups [logs] deterministically by card key and chronological timestamp.
  static List<List<_ReplayStep>> _buildSequences(List<PracticeReviewLog> logs) {
    if (logs.isEmpty) return const [];
    final byCard = <String, List<(int index, PracticeReviewLog log)>>{};
    for (var i = 0; i < logs.length; i++) {
      final log = logs[i];
      (byCard[log.cardKey] ??= []).add((i, log));
    }
    final keys = byCard.keys.toList()..sort();
    final sequences = <List<_ReplayStep>>[];
    for (final key in keys) {
      final entries = byCard[key]!
        ..sort((a, b) {
          final cmp = a.$2.reviewedAt.toUtc().compareTo(
            b.$2.reviewedAt.toUtc(),
          );
          return cmp != 0 ? cmp : a.$1.compareTo(b.$1);
        });
      final steps = <_ReplayStep>[];
      DateTime? previousAt;
      for (var i = 0; i < entries.length; i++) {
        final log = entries[i].$2;
        final at = log.reviewedAt.toUtc();
        final wholeDays = previousAt == null
            ? 0
            : _wholeDays(at.difference(previousAt));
        final exactDays = previousAt == null
            ? 0.0
            : math.max<double>(
                0,
                at.difference(previousAt).inMicroseconds /
                    Duration.microsecondsPerDay,
              );
        final scoreDays = wholeDays >= 1
            ? wholeDays.toDouble()
            : math.max(exactDays, log.elapsedDays);
        final scored =
            i > 0 &&
            (wholeDays >= 1 ||
                (log.state == FsrsState.review && scoreDays > 0));
        steps.add(
          _ReplayStep(
            rating: log.rating,
            grade: log.rating.grade,
            reviewedAt: at,
            wholeDays: math.max(0, wholeDays),
            scoreDays: scoreDays,
            scored: scored,
            recalled: log.rating != FsrsRating.again,
          ),
        );
        previousAt = at;
      }
      if (steps.isNotEmpty) sequences.add(steps);
    }
    return sequences;
  }

  static int _wholeDays(Duration duration) {
    final micros = duration.inMicroseconds;
    const perDay = Duration.microsecondsPerDay;
    return micros >= 0 ? micros ~/ perDay : -((-micros + perDay - 1) ~/ perDay);
  }
}

final class _ReplayStep {
  const new({
    required this.rating,
    required this.grade,
    required this.reviewedAt,
    required this.wholeDays,
    required this.scoreDays,
    required this.scored,
    required this.recalled,
  });

  final FsrsRating rating;
  final int grade;
  final DateTime reviewedAt;
  final int wholeDays;
  final double scoreDays;
  final bool scored;
  final bool recalled;
}
