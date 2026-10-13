import 'package:equatable/equatable.dart';
import 'package:mozhi/usage/models/usage_budget.dart';
import 'package:mozhi/usage/models/usage_month.dart';
import 'package:mozhi/usage/models/usage_stats.dart';

/// Immutable view of all tracked usage at one point in time.
class UsageSnapshot extends Equatable {
  const UsageSnapshot({
    required this.currentMonth,
    this.months = const {},
    this.budgets = const {},
  });

  /// The month that "this month" refers to.
  final UsageMonth currentMonth;

  /// Usage per month, then per provider id. Months without usage are absent.
  final Map<UsageMonth, Map<String, UsageStats>> months;

  /// Budgets per provider id.
  final Map<String, UsageBudget> budgets;

  UsageMonth get lastMonth => currentMonth.previous;

  /// Usage of [providerId] in [month] (default: [currentMonth]).
  UsageStats statsFor(String providerId, {UsageMonth? month}) =>
      months[month ?? currentMonth]?[providerId] ?? UsageStats.zero;

  /// Usage of all providers in [month] (default: [currentMonth]).
  UsageStats totalFor({UsageMonth? month}) =>
      (months[month ?? currentMonth]?.values ?? const <UsageStats>[]).fold(
        UsageStats.zero,
        (sum, stats) => sum + stats,
      );

  UsageBudget? budgetFor(String providerId) => budgets[providerId];

  /// This month's usage of [providerId] against its budget, if it has one.
  UsageBudgetStatus? budgetStatus(String providerId) =>
      budgets[providerId]?.statusFor(statsFor(providerId));

  /// Usage of [providerId] in the [count] months ending with [currentMonth],
  /// oldest first.
  List<UsageStats> history(String providerId, {int count = 6}) => [
    for (var i = count - 1; i >= 0; i--)
      statsFor(providerId, month: currentMonth.shift(-i)),
  ];

  /// Ids of providers with any recorded usage or a budget, sorted.
  List<String> get providerIds =>
      {
        for (final perProvider in months.values)
          for (final MapEntry(:key, :value) in perProvider.entries)
            if (!value.isEmpty) key,
        ...budgets.keys,
      }.toList()
        ..sort();

  bool get isEmpty =>
      budgets.isEmpty &&
      months.values.every((m) => m.values.every((s) => s.isEmpty));

  @override
  List<Object?> get props => [currentMonth, months, budgets];
}
