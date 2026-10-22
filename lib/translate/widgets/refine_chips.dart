import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
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

/// The refinement chips (Kagi translation suggestions) as one wrapping
/// row: the first [maxVisible] chips (the everyday ones: more formal, more
/// casual, shorter, simpler) and every applied or pending chip, then a "+"
/// chip whose menu holds the other refinements and "More suggestions"
/// (fetched for the translation; the menu stays open while they load).
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
  const new({required this.state, this.maxVisible = 4, super.key});

  final TranslateState state;

  /// How many chips show before the others go into the "+" menu (applied
  /// and pending chips always show).
  final int maxVisible;

  /// The chips of [state] that show as chips (in their order): the first
  /// [maxVisible], and any applied or pending one after them. The others
  /// are in the "+" menu.
  static List<RefinementSuggestion> visibleSuggestions(
    TranslateState state, {
    int maxVisible = 4,
  }) => [
    for (final (index, suggestion) in state.suggestions.indexed)
      if (index < maxVisible ||
          state.isSuggestionApplied(suggestion) ||
          state.pendingRefinement == suggestion)
        suggestion,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<TranslateCubit>();
    final stacks =
        state.refinesOutput ||
        state.appliedRefinements.isNotEmpty ||
        state.isRefining;
    final visible = visibleSuggestions(state, maxVisible: maxVisible);
    final hidden = [
      for (final suggestion in state.suggestions)
        if (!visible.contains(suggestion)) suggestion,
    ];
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.translateRefine,
      child: TranslatePills(
        child: Wrap(
          key: const Key('translate_refinement_chips'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final suggestion in visible)
              _chip(
                context,
                suggestion,
                index: state.suggestions.indexOf(suggestion),
                stacks: stacks,
                onPressed: () => unawaited(cubit.applySuggestion(suggestion)),
              ),
            _MoreRefinements(state: state, hidden: hidden),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    RefinementSuggestion suggestion, {
    required int index,
    required bool stacks,
    required VoidCallback onPressed,
  }) {
    final key = ValueKey('translate_refinement_chip:$index');
    if (stacks) {
      return _RefinementFilterChip(
        key: key,
        state: state,
        suggestion: suggestion,
        onPressed: onPressed,
      );
    }
    return ActionChip(
      key: key,
      avatar: Icon(refinementIcon(suggestion.icon)),
      label: Text(refinementLabel(context.l10n, suggestion)),
      tooltip: suggestion.description.isEmpty ? null : suggestion.description,
      onPressed: onPressed,
    );
  }
}

/// The "+" chip after the refinement chips: a menu with the [hidden]
/// refinements and "More suggestions" (a spinner while they load). Nothing
/// when there is nothing to offer.
class _MoreRefinements extends StatelessWidget {
  const new({required this.state, required this.hidden});

  final TranslateState state;
  final List<RefinementSuggestion> hidden;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<TranslateCubit>();
    final loading = state.suggestionsStatus == ExtraStatus.loading;
    final canLoadMore = state.suggestionsStatus != ExtraStatus.ready;
    if (hidden.isEmpty && !loading && !canLoadMore) {
      return const SizedBox.shrink();
    }
    return MenuAnchor(
      menuChildren: [
        for (final suggestion in hidden)
          MenuItemButton(
            key: ValueKey(
              'translate_refinement_menu:'
              '${state.suggestions.indexOf(suggestion)}',
            ),
            leadingIcon: Icon(refinementIcon(suggestion.icon)),
            onPressed: () => unawaited(cubit.applySuggestion(suggestion)),
            child: Text(refinementLabel(l10n, suggestion)),
          ),
        if (loading)
          MenuItemButton(
            key: const Key('translate_more_suggestions_loading'),
            leadingIcon: _Spinner(label: l10n.translateLoading),
            child: Text(l10n.translateMoreSuggestions),
          )
        else if (canLoadMore)
          MenuItemButton(
            key: const Key('translate_more_suggestions'),
            leadingIcon: const Icon(Icons.auto_awesome),
            // Stays open: the suggestions appear in it once loaded.
            closeOnActivate: false,
            onPressed: () => unawaited(cubit.loadSuggestions()),
            child: Text(l10n.translateMoreSuggestions),
          ),
      ],
      builder: (context, controller, _) => ActionChip(
        key: const Key('translate_refinement_more'),
        avatar: loading ? _Spinner(label: l10n.translateLoading) : null,
        label: const Icon(Icons.add, size: 18),
        tooltip: l10n.translateRefineMoreMenu,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The ranges of [after] (UTF-16 offsets) that a word diff from [before]
/// marks as new or changed (`ProofreadDiff.wordDiff`), without the
/// whitespace around them: what a refinement changed in the translation.
List<TextRange> changedWordRanges(String before, String after) {
  final ranges = <TextRange>[];
  var position = 0;
  for (final segment in ProofreadDiff.wordDiff(before, after)) {
    switch (segment.type) {
      case DiffType.removed:
        continue;
      case DiffType.unchanged:
        position += segment.text.length;
      case DiffType.inserted:
        final text = segment.text;
        final start = position + text.length - text.trimLeft().length;
        final end = position + text.trimRight().length;
        if (end > start) ranges.add(TextRange(start: start, end: end));
        position += text.length;
    }
  }
  return ranges;
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
