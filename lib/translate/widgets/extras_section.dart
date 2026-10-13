import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart';
import 'package:mozhi/translate/widgets/explain_sheet.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// AI extras under a finished translation: refinement chips (AI engines),
/// alternatives, explain and (short inputs) a dictionary card.
class ExtrasSection extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      builder: (context, state) {
        if (!state.hasExtras ||
            state.output.trim().isEmpty ||
            state.status != TranslateStatus.success) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.isAiEngine) ...[
              const SizedBox(height: TranslateLayout.gap),
              RefinementChips(state: state),
            ],
            const SizedBox(height: TranslateLayout.gap),
            _ExtrasCard(state: state),
            if (state.isShortInput) ...[
              const SizedBox(height: TranslateLayout.gap),
              const DictionaryCard(),
            ],
          ],
        );
      },
    );
  }
}

IconData _suggestionIcon(String name) => switch (name) {
  'formal' => Icons.work_outline,
  'casual' => Icons.emoji_emotions_outlined,
  'shorter' => Icons.compress,
  'longer' => Icons.notes,
  'simplify' => Icons.auto_fix_high_outlined,
  'fluent' => Icons.record_voice_over_outlined,
  'literal' => Icons.format_quote_outlined,
  _ => Icons.tune,
};

/// Horizontally scrolling refinement chips (Kagi translation suggestions).
class RefinementChips extends StatelessWidget {
  const new({required this.state, super.key});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<TranslateCubit>();
    final loading = state.suggestionsStatus == ExtraStatus.loading;
    final canLoadMore = state.suggestionsStatus != ExtraStatus.ready;
    return Semantics(
      container: true,
      label: l10n.translateRefine,
      child: SingleChildScrollView(
        key: const Key('translate_refinement_chips'),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final suggestion in state.suggestions)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: ActionChip(
                  avatar: Icon(_suggestionIcon(suggestion.icon)),
                  label: Text(suggestion.label),
                  tooltip: suggestion.description.isEmpty
                      ? null
                      : suggestion.description,
                  onPressed: () => unawaited(cubit.applySuggestion(suggestion)),
                ),
              ),
            if (loading || canLoadMore)
              ActionChip(
                key: const Key('translate_more_suggestions'),
                avatar: loading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(l10n.translateMoreSuggestions),
                onPressed: loading
                    ? null
                    : () => unawaited(cubit.loadSuggestions()),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExtrasCard extends StatelessWidget {
  const new({required this.state});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<TranslateCubit>();
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
      ),
      child: Column(
        children: [
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              // Collapse whenever the translation changes.
              key: ValueKey('alternatives:${state.output}'),
              leading: const Icon(Icons.alt_route),
              title: Text(l10n.translateAlternatives),
              onExpansionChanged: (expanded) {
                if (expanded &&
                    (state.alternativesStatus == ExtraStatus.idle ||
                        state.alternativesStatus == ExtraStatus.failure)) {
                  unawaited(cubit.loadAlternatives());
                }
              },
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [AlternativesList(state: state)],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            key: const Key('translate_explain_button'),
            leading: const Icon(Icons.school_outlined),
            title: Text(l10n.translateExplain),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              if (state.explainStatus == ExtraStatus.idle ||
                  state.explainStatus == ExtraStatus.failure) {
                unawaited(cubit.explain());
              }
              unawaited(showExplainSheet(context));
            },
          ),
        ],
      ),
    );
  }
}

/// Body of the "Alternatives" panel.
class AlternativesList extends StatelessWidget {
  const new({required this.state, super.key});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<TranslateCubit>();
    final alternatives = state.alternatives;
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    switch (state.alternativesStatus) {
      case ExtraStatus.idle:
        return const SizedBox.shrink();
      case ExtraStatus.loading:
        return const Padding(
          padding: padding,
          child: LinearProgressIndicator(
            key: Key('translate_alternatives_progress'),
          ),
        );
      case ExtraStatus.failure:
        return Padding(
          padding: padding,
          child: TranslateErrorView(
            error: state.extraError,
            dense: true,
            onRetry: () => unawaited(cubit.loadAlternatives()),
          ),
        );
      case ExtraStatus.ready:
        if (alternatives == null || alternatives.alternatives.isEmpty) {
          return Padding(
            padding: padding,
            child: Text(l10n.translateAlternativesEmpty),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (alternatives.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  alternatives.description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final Alternative(:text, :explanation)
                in alternatives.alternatives)
              ListTile(
                title: Text(text),
                subtitle: explanation.isEmpty ? null : Text(explanation),
                trailing: const Icon(Icons.north_west),
                onTap: () => cubit.useAlternative(text),
              ),
          ],
        );
    }
  }
}
