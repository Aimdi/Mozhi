import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_colors.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:mozhi/proofread/widgets/proofread_result_section.dart'
    show ProofreadPill;
import 'package:translation_repository/translation_repository.dart';

/// One suggested edit as a flat row: category pill, original ->
/// replacement, explanation and an accept/reject checkbox, with a hairline
/// below unless it is the last one ([divider]).
class ProofreadEditTile extends StatelessWidget {
  const new({
    required this.edit,
    required this.accepted,
    required this.onToggle,
    this.located = true,
    this.divider = false,
    super.key,
  });

  final ProofreadEdit edit;
  final bool accepted;
  final VoidCallback onToggle;

  /// False when the edit's original text could not be found in the input.
  final bool located;

  /// Whether a hairline separates this row from the next.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final explanation = edit.explanation.trim();
    final subtitleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: AppPalette.of(context).secondaryText,
    );

    final tile = Semantics(
      container: true,
      child: CheckboxListTile(
        value: accepted,
        onChanged: (_) => onToggle(),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsetsDirectional.only(end: 4),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: ProofreadCategoryChip(category: edit.category),
            ),
            ProofreadEditChange(edit: edit),
          ],
        ),
        subtitle: explanation.isEmpty && located
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    if (explanation.isNotEmpty)
                      Text(explanation, style: subtitleStyle),
                    if (!located)
                      Text(
                        l10n.proofreadEditNotFound,
                        style: subtitleStyle?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
    if (!divider) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [tile, const Hairline()],
    );
  }
}

/// `original → replacement` with diff colors.
class ProofreadEditChange extends StatelessWidget {
  const new({required this.edit, this.style, super.key});

  final ProofreadEdit edit;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final colors = ProofreadDiffColors.of(context);
    final l10n = context.l10n;
    final hasOriginal = edit.original.isNotEmpty;
    final hasReplacement = edit.replacement.isNotEmpty;
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (hasOriginal)
            TextSpan(
              text: edit.original,
              style: colors.removedStyle,
              semanticsLabel: l10n.proofreadRemovedSemantics(edit.original),
            ),
          if (hasOriginal && hasReplacement)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.arrow_forward,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  semanticLabel: l10n.proofreadChangedTo,
                ),
              ),
            ),
          if (hasReplacement)
            TextSpan(
              text: edit.replacement,
              style: colors.insertedStyle,
              semanticsLabel: l10n.proofreadInsertedSemantics(edit.replacement),
            ),
        ],
      ),
    );
  }
}

/// Small outlined pill naming an edit category.
class ProofreadCategoryChip extends StatelessWidget {
  const new({required this.category, super.key});

  final String category;

  @override
  Widget build(BuildContext context) {
    return ProofreadPill(
      icon: proofreadCategoryIcon(category),
      label: context.l10n.proofreadCategory(category),
    );
  }
}
