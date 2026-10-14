import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Icon of a refinement chip ([RefinementSuggestion.icon] hint).
IconData refinementIcon(String name) => switch (name) {
  'formal' => Icons.work_outline,
  'casual' => Icons.emoji_emotions_outlined,
  'shorter' => Icons.compress,
  'longer' => Icons.notes,
  'simplify' => Icons.auto_fix_high_outlined,
  'fluent' => Icons.record_voice_over_outlined,
  'literal' => Icons.format_quote_outlined,
  _ => Icons.tune,
};

/// Labels of the built-in chips ([RefinementSuggestion.defaults]) by
/// their icon hint.
final Map<String, String Function(AppLocalizations l10n)> _defaultLabels = {
  'formal': (l10n) => l10n.translateRefineMoreFormal,
  'casual': (l10n) => l10n.translateRefineMoreCasual,
  'shorter': (l10n) => l10n.translateRefineShorter,
  'simplify': (l10n) => l10n.translateRefineSimpler,
  'fluent': (l10n) => l10n.translateRefineMoreFluent,
  'literal': (l10n) => l10n.translateRefineMoreLiteral,
};

/// Label of [suggestion] in the UI language: built-in chips
/// ([RefinementSuggestion.defaults]) are translated, fetched suggestions
/// keep the label the model wrote.
String refinementLabel(AppLocalizations l10n, RefinementSuggestion suggestion) {
  final label = RefinementSuggestion.defaults.contains(suggestion)
      ? _defaultLabels[suggestion.icon]
      : null;
  return label == null ? suggestion.label : label(l10n);
}

/// Horizontally scrolling refinement chips (Kagi translation suggestions)
/// and "More suggestions".
///
/// When the chips revise the current translation
/// ([TranslateState.refinesOutput], AI engines with the general prompt
/// profile) they are filter chips: an applied chip is selected (check
/// mark, "selected" for screen readers) and tapping it again undoes it.
/// Chips of one [RefinementSuggestion.exclusiveGroup] behave like radio
/// chips: applying one replaces the applied chip of its group (its tooltip
/// says which). The chip in flight shows a spinner; tapping it cancels.
///
/// Otherwise (machine translation engines, translation-only models) each
/// chip translates the input again with its instruction, once.
class RefinementChips extends StatelessWidget {
  const new({required this.state, super.key});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<TranslateCubit>();
    final loading = state.suggestionsStatus == ExtraStatus.loading;
    final canLoadMore = state.suggestionsStatus != ExtraStatus.ready;
    final stacks =
        state.refinesOutput ||
        state.appliedRefinements.isNotEmpty ||
        state.isRefining;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.translateRefine,
      child: SingleChildScrollView(
        key: const Key('translate_refinement_chips'),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (index, suggestion) in state.suggestions.indexed)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: stacks
                    ? _RefinementFilterChip(
                        key: ValueKey('translate_refinement_chip:$index'),
                        state: state,
                        suggestion: suggestion,
                        onPressed: () =>
                            unawaited(cubit.applySuggestion(suggestion)),
                      )
                    : ActionChip(
                        key: ValueKey('translate_refinement_chip:$index'),
                        avatar: Icon(refinementIcon(suggestion.icon)),
                        label: Text(refinementLabel(l10n, suggestion)),
                        tooltip: suggestion.description.isEmpty
                            ? null
                            : suggestion.description,
                        onPressed: () =>
                            unawaited(cubit.applySuggestion(suggestion)),
                      ),
              ),
            if (loading || canLoadMore)
              ActionChip(
                key: const Key('translate_more_suggestions'),
                avatar: loading
                    ? _Spinner(label: l10n.translateLoading)
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

/// A refinement chip that revises the output: selected while applied,
/// a spinner while in flight.
class _RefinementFilterChip extends StatelessWidget {
  const new({
    required this.state,
    required this.suggestion,
    required this.onPressed,
    super.key,
  });

  final TranslateState state;
  final RefinementSuggestion suggestion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = refinementLabel(l10n, suggestion);
    final applied = state.isSuggestionApplied(suggestion);
    final pending = state.pendingRefinement == suggestion;
    final replaced = applied ? null : _replacedBy(state, suggestion);
    final String? tooltip;
    if (pending) {
      tooltip = l10n.translateRefinementCancel(label);
    } else if (applied) {
      tooltip = l10n.translateRefinementUndo(label);
    } else if (replaced != null) {
      tooltip = l10n.translateRefinementReplaces(
        refinementLabel(l10n, replaced),
      );
    } else {
      tooltip = suggestion.description.isEmpty ? null : suggestion.description;
    }
    return FilterChip(
      selected: applied,
      // The check mark takes the icon's place while selected.
      avatar: pending
          ? _Spinner(label: l10n.translateLoading)
          : applied
          ? null
          : Icon(refinementIcon(suggestion.icon)),
      label: Text(label),
      tooltip: tooltip,
      onSelected: (_) => onPressed(),
    );
  }

  /// The applied chip that applying [suggestion] would replace (same
  /// exclusive group), or null.
  static RefinementSuggestion? _replacedBy(
    TranslateState state,
    RefinementSuggestion suggestion,
  ) {
    final group = suggestion.exclusiveGroup;
    if (group == null) return null;
    for (final applied in state.appliedSuggestions) {
      if (applied.exclusiveGroup == group) return applied;
    }
    return null;
  }
}

class _Spinner extends StatelessWidget {
  const new({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: label),
  );
}
