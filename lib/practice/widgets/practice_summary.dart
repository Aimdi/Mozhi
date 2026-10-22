import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/cubit/practice_cubit.dart';
import 'package:mozhi/practice/widgets/practice_texts.dart';

/// The end of a session of the [PracticeCubit] above it: how many cards
/// were reviewed, remembered and learned, when the next ones are due,
/// "Keep going" when more are due already, and Done (the overview). With
/// nothing reviewed: nothing was due. No streaks, no scores.
class PracticeSummary extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final state = context.watch<PracticeCubit>().state;
    final stats = state.stats;
    final deck = state.deck;
    final now = DateTime.now();
    final more =
        deck != null &&
        (deck.due(now).isNotEmpty || deck.newCards().isNotEmpty);
    final next = deck?.nextDue(now);
    final reviewed = stats.reviewed > 0;
    final lines = [
      if (reviewed) ...[
        l10n.practiceSummaryReviewed(stats.reviewed),
        l10n.practiceSummaryRemembered(stats.remembered),
        if (stats.newCards > 0) l10n.practiceSummaryNew(stats.newCards),
      ],
      if (!more && next != null)
        l10n.practiceNextDue(practiceIntervalText(l10n, next.difference(now))),
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    reviewed ? Icons.check_rounded : Icons.event_available,
                    size: 32,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  reviewed
                      ? l10n.practiceSummaryTitle
                      : l10n.practiceNothingDueTitle,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (more)
                    FilledButton(
                      key: const Key('practice_keep_going'),
                      onPressed: () =>
                          unawaited(context.read<PracticeCubit>().start()),
                      child: Text(l10n.practiceKeepGoing),
                    ),
                  if (more)
                    OutlinedButton(
                      key: const Key('practice_done'),
                      onPressed: () => unawaited(
                        context.read<PracticeCubit>().backToOverview(),
                      ),
                      child: Text(l10n.practiceDone),
                    )
                  else
                    FilledButton(
                      key: const Key('practice_done'),
                      onPressed: () => unawaited(
                        context.read<PracticeCubit>().backToOverview(),
                      ),
                      child: Text(l10n.practiceDone),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
