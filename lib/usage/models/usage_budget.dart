import 'package:equatable/equatable.dart';
import 'package:mozhi/usage/models/usage_month.dart';
import 'package:mozhi/usage/models/usage_stats.dart';

/// How close a provider is to its [UsageBudget], from least to most urgent.
enum UsageBudgetLevel {
  /// Below the warning threshold.
  ok,

  /// At or above the warning threshold (80 % by default).
  nearLimit,

  /// At or above the budget.
  limitReached,
}

/// A per-provider monthly budget in characters (sent + received).
class UsageBudget extends Equatable {
  const UsageBudget({
    required this.monthlyChars,
    this.warningThreshold = defaultWarningThreshold,
  }) : assert(monthlyChars > 0, 'monthlyChars must be positive'),
       assert(
         warningThreshold > 0 && warningThreshold <= 1,
         'warningThreshold must be in (0, 1]',
       );

  /// Returns null for missing or invalid budgets; an invalid threshold falls
  /// back to [defaultWarningThreshold].
  static UsageBudget? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final chars = json['monthlyChars'];
    if (chars is! num || !chars.isFinite || chars < 1) return null;
    final threshold = json['warningThreshold'];
    return UsageBudget(
      monthlyChars: chars.toInt(),
      warningThreshold:
          threshold is num &&
              threshold.isFinite &&
              threshold > 0 &&
              threshold <= 1
          ? threshold.toDouble()
          : defaultWarningThreshold,
    );
  }

  /// Warn at 80 % of the budget.
  static const defaultWarningThreshold = 0.8;

  final int monthlyChars;

  /// Fraction of [monthlyChars] at which a warning is raised.
  final double warningThreshold;

  /// Characters at which [UsageBudgetLevel.nearLimit] starts.
  int get warningChars => (monthlyChars * warningThreshold).ceil();

  UsageBudgetLevel levelFor(int usedChars) {
    if (usedChars >= monthlyChars) return UsageBudgetLevel.limitReached;
    if (usedChars >= warningChars) return UsageBudgetLevel.nearLimit;
    return UsageBudgetLevel.ok;
  }

  UsageBudgetStatus statusFor(UsageStats stats) =>
      UsageBudgetStatus(budget: this, usedChars: stats.totalChars);

  Map<String, dynamic> toJson() => {
    'monthlyChars': monthlyChars,
    'warningThreshold': warningThreshold,
  };

  @override
  List<Object?> get props => [monthlyChars, warningThreshold];
}

/// Usage measured against a [UsageBudget].
class UsageBudgetStatus extends Equatable {
  const UsageBudgetStatus({required this.budget, required this.usedChars});

  final UsageBudget budget;
  final int usedChars;

  /// Used share of the budget; may exceed 1.
  double get fraction => usedChars / budget.monthlyChars;

  int get remainingChars =>
      usedChars >= budget.monthlyChars ? 0 : budget.monthlyChars - usedChars;

  UsageBudgetLevel get level => budget.levelFor(usedChars);

  @override
  List<Object?> get props => [budget, usedChars];
}

/// Raised by `UsageTracker.warnings` the first time in a [month] that a
/// provider reaches [level] of its budget.
class UsageWarning extends Equatable {
  const UsageWarning({
    required this.providerId,
    required this.month,
    required this.level,
    required this.usedChars,
    required this.budget,
  });

  final String providerId;
  final UsageMonth month;

  /// [UsageBudgetLevel.nearLimit] or [UsageBudgetLevel.limitReached].
  final UsageBudgetLevel level;
  final int usedChars;
  final UsageBudget budget;

  /// Used share of the budget; may exceed 1.
  double get fraction => usedChars / budget.monthlyChars;

  @override
  List<Object?> get props => [providerId, month, level, usedChars, budget];
}
