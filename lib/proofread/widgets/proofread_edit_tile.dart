import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_colors.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// One suggested edit: category, original -> replacement, explanation and an
/// accept/reject checkbox.
class ProofreadEditTile extends StatelessWidget {
  const new({
    required this.edit,
    required this.accepted,
    required this.onToggle,
    this.located = true,
    super.key,
  });

  final ProofreadEdit edit;
  final bool accepted;
  final VoidCallback onToggle;

  /// False when the edit's original text could not be found in the input.
  final bool located;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final explanation = edit.explanation.trim();
    final subtitleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: CheckboxListTile(
        value: accepted,
        onChanged: (_) => onToggle(),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsetsDirectional.only(start: 8, end: 16),
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

/// Small tonal label for an edit category.
class ProofreadCategoryChip extends StatelessWidget {
  const new({required this.category, super.key});

  final String category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Icon(
              proofreadCategoryIcon(category),
              size: 14,
              color: scheme.onSecondaryContainer,
            ),
            Flexible(
              child: Text(
                context.l10n.proofreadCategory(category),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
