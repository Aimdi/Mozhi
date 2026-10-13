import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/usage/cubit/usage_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/usage/widgets/usage_bars.dart';
import 'package:mozhi/usage/widgets/usage_budget_dialog.dart';
import 'package:mozhi/usage/widgets/usage_format.dart';

/// Usage of one AI provider (this and last month, a 6-month chart) and its
/// monthly budget, for the provider editor or settings.
///
/// Reads the [UsageTracker] provided above unless [tracker] is given.
class UsageCard extends StatelessWidget {
  const UsageCard({
    required this.providerId,
    this.tracker,
    this.onShowAll,
    super.key,
  });

  final String providerId;
  final UsageTracker? tracker;

  /// Shows an "All providers" button, e.g. to open the usage summary page.
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = UsageCubit(tracker ?? context.read<UsageTracker>());
        unawaited(cubit.load());
        return cubit;
      },
      child: UsageCardView(providerId: providerId, onShowAll: onShowAll),
    );
  }
}

/// Builds [UsageCard] from the [UsageCubit] above.
class UsageCardView extends StatelessWidget {
  const UsageCardView({required this.providerId, this.onShowAll, super.key});

  /// Number of months in the chart.
  static const historyMonths = 6;

  final String providerId;
  final VoidCallback? onShowAll;

  Future<void> _editBudget(BuildContext context, UsageBudget? current) async {
    final cubit = context.read<UsageCubit>();
    final choice = await showUsageBudgetDialog(context, current: current);
    if (choice == null) return;
    await cubit.setBudget(providerId, choice.monthlyChars);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final snapshot = context.select((UsageCubit c) => c.state.snapshot);
    final stats = snapshot.statsFor(providerId);
    final last = snapshot.statsFor(providerId, month: snapshot.lastMonth);
    final budget = snapshot.budgetFor(providerId);
    final status = snapshot.budgetStatus(providerId);
    final months = [
      for (var i = historyMonths - 1; i >= 0; i--)
        snapshot.currentMonth.shift(-i),
    ];
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.data_usage_outlined, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.usageTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                if (status != null && status.level != UsageBudgetLevel.ok)
                  UsageLevelBadge(level: status.level),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.usageThisMonth,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              [
                context.usageRequests(stats.requests),
                context.usageCharacters(stats.totalChars),
                context.usageTokens(stats.estimatedTokens),
              ].join(' · '),
              style: theme.textTheme.bodyLarge,
            ),
            Text(
              l10n.usageInputOutput(
                context.usageNumber(stats.inputChars),
                context.usageNumber(stats.outputChars),
              ),
              style: secondary,
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.usageLastMonth}: '
              '${context.usageRequests(last.requests)} · '
              '${context.usageCharacters(last.totalChars)} · '
              '${context.usageTokens(last.estimatedTokens)}',
              style: secondary,
            ),
            const SizedBox(height: 16),
            UsageHistoryChart(
              months: months,
              values: [
                for (final month in months)
                  snapshot.statsFor(providerId, month: month).totalChars,
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text(l10n.usageBudgetTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (status == null)
              Text(l10n.usageBudgetNone, style: secondary)
            else
              UsageBudgetProgress(status: status),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                if (onShowAll != null)
                  TextButton(
                    onPressed: onShowAll,
                    child: Text(l10n.usageViewAll),
                  ),
                TextButton.icon(
                  onPressed: () => _editBudget(context, budget),
                  icon: const Icon(Icons.savings_outlined),
                  label: Text(
                    budget == null ? l10n.usageBudgetSet : l10n.usageBudgetEdit,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Progress bar and "used of limit" text of a [UsageBudgetStatus].
class UsageBudgetProgress extends StatelessWidget {
  const UsageBudgetProgress({required this.status, super.key});

  final UsageBudgetStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = context.l10n.usageBudgetProgress(
      context.usageNumber(status.usedChars),
      context.usageNumber(status.budget.monthlyChars),
      context.usagePercent((status.fraction * 100).floor() / 100),
    );
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: UsageBar(
              fraction: status.fraction,
              color: context.usageLevelColor(status.level),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Near budget" / "Budget reached" badge; nothing for [UsageBudgetLevel.ok].
class UsageLevelBadge extends StatelessWidget {
  const UsageLevelBadge({required this.level, super.key});

  final UsageBudgetLevel level;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (label, icon) = switch (level) {
      UsageBudgetLevel.ok => (null, null),
      UsageBudgetLevel.nearLimit => (
        l10n.usageBudgetNearLimit,
        Icons.warning_amber_rounded,
      ),
      UsageBudgetLevel.limitReached => (
        l10n.usageBudgetLimitReached,
        Icons.block,
      ),
    };
    if (label == null) return const SizedBox.shrink();
    final color = context.usageLevelColor(level);
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
