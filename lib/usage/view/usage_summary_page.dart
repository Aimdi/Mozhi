import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/usage/cubit/usage_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/usage/widgets/usage_bars.dart';
import 'package:mozhi/usage/widgets/usage_card.dart';
import 'package:mozhi/usage/widgets/usage_format.dart';
import 'package:translation_repository/translation_repository.dart';

/// Usage of every AI provider this and last month, with bars to compare
/// them and a reset action.
///
/// Reads the [UsageTracker] provided above unless [tracker] is given.
class UsageSummaryPage extends StatelessWidget {
  const new({
    this.providers = const [],
    this.tracker,
    this.onOpenProvider,
    super.key,
  });

  /// Configured providers, in display order. Providers with recorded usage
  /// that are not in this list are shown as "Removed provider".
  final List<AiProviderConfig> providers;
  final UsageTracker? tracker;

  /// Called with a provider id when its row is tapped (e.g. to open the
  /// provider editor); rows are not tappable when null.
  final ValueChanged<String>? onOpenProvider;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = UsageCubit(tracker ?? context.read<UsageTracker>());
        unawaited(cubit.load());
        return cubit;
      },
      child: UsageSummaryView(
        providers: providers,
        onOpenProvider: onOpenProvider,
      ),
    );
  }
}

class UsageSummaryView extends StatelessWidget {
  const new({this.providers = const [], this.onOpenProvider, super.key});

  final List<AiProviderConfig> providers;
  final ValueChanged<String>? onOpenProvider;

  Future<void> _confirmReset(BuildContext context) async {
    final cubit = context.read<UsageCubit>();
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.usageResetTitle),
        content: Text(l10n.usageResetBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.usageResetConfirm),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await cubit.reset();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<UsageCubit>().state;
    final snapshot = state.snapshot;
    final loading =
        snapshot.isEmpty &&
        (state.status == UsageStatus.initial ||
            state.status == UsageStatus.loading);

    final names = {for (final p in providers) p.id: p.name};
    final ids = [
      for (final p in providers) p.id,
      for (final id in snapshot.providerIds)
        if (!names.containsKey(id)) id,
    ];
    final maxChars = ids.fold(0, (max, id) {
      final thisMonth = snapshot.statsFor(id).totalChars;
      final lastMonth = snapshot
          .statsFor(id, month: snapshot.lastMonth)
          .totalChars;
      return math.max(max, math.max(thisMonth, lastMonth));
    });
    final hasUsage = snapshot.hasUsage;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.usageTitle),
        actions: [
          if (hasUsage)
            IconButton(
              onPressed: () => _confirmReset(context),
              tooltip: l10n.usageResetAction,
              icon: const Icon(Icons.restart_alt),
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final gutter = math.max(16, (constraints.maxWidth - 720) / 2);
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    gutter.toDouble(),
                    8,
                    gutter.toDouble(),
                    32,
                  ),
                  children: [
                    if (ids.isEmpty)
                      const _EmptyUsage()
                    else ...[
                      _MonthTotals(snapshot: snapshot),
                      const SizedBox(height: 16),
                      for (final id in ids) ...[
                        ProviderUsageTile(
                          name: names[id] ?? l10n.usageUnknownProvider,
                          thisMonth: snapshot.statsFor(id),
                          lastMonth: snapshot.statsFor(
                            id,
                            month: snapshot.lastMonth,
                          ),
                          maxChars: maxChars,
                          budgetStatus: snapshot.budgetStatus(id),
                          onTap: onOpenProvider != null && names.containsKey(id)
                              ? () => onOpenProvider!(id)
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.usageDisclaimer,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _EmptyUsage extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.data_usage_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.usageEmptyTitle,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.usageEmptyBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Totals of all providers this month, compared with last month.
class _MonthTotals extends StatelessWidget {
  const new({required this.snapshot});

  final UsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final total = snapshot.totalFor();
    final last = snapshot.totalFor(month: snapshot.lastMonth);
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                context.usageMonthYear(snapshot.currentMonth),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.usageCharacters(total.totalChars),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            Text(
              '${context.usageRequests(total.requests)} · '
              '${context.usageTokens(total.estimatedTokens)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.usageLastMonth}: '
              '${context.usageCharacters(last.totalChars)} · '
              '${context.usageRequests(last.requests)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One provider's usage this and last month as two bars scaled to
/// [maxChars], plus its budget progress.
class ProviderUsageTile extends StatelessWidget {
  const new({
    required this.name,
    required this.thisMonth,
    required this.lastMonth,
    required this.maxChars,
    this.budgetStatus,
    this.onTap,
    super.key,
  });

  final String name;
  final UsageStats thisMonth;
  final UsageStats lastMonth;

  /// Characters that fill a bar completely (the largest value shown).
  final int maxChars;
  final UsageBudgetStatus? budgetStatus;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final status = budgetStatus;
    final unused = thisMonth.isEmpty && lastMonth.isEmpty;
    double fraction(UsageStats stats) =>
        maxChars <= 0 ? 0 : stats.totalChars / maxChars;

    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (status != null && status.level != UsageBudgetLevel.ok)
                    UsageLevelBadge(level: status.level),
                  if (onTap != null)
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 8),
              if (unused)
                Text(
                  l10n.usageNotUsed,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else ...[
                _BarRow(
                  label: l10n.usageThisMonth,
                  value: context.usageCharacters(thisMonth.totalChars),
                  fraction: fraction(thisMonth),
                  color: scheme.primary,
                ),
                const SizedBox(height: 8),
                _BarRow(
                  label: l10n.usageLastMonth,
                  value: context.usageCharacters(lastMonth.totalChars),
                  fraction: fraction(lastMonth),
                  color: scheme.tertiary,
                ),
                const SizedBox(height: 8),
                Text(
                  '${context.usageRequests(thisMonth.requests)} · '
                  '${context.usageTokens(thisMonth.estimatedTokens)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (status != null) ...[
                const SizedBox(height: 12),
                UsageBudgetProgress(status: status),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const new({
    required this.label,
    required this.value,
    required this.fraction,
    required this.color,
  });

  final String label;
  final String value;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: style)),
              Text(value, style: style),
            ],
          ),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: UsageBar(fraction: fraction, color: color),
          ),
        ],
      ),
    );
  }
}
