import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_colors.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:mozhi/proofread/widgets/proofread_result_section.dart'
    show ProofreadPill;
import 'package:translation_repository/translation_repository.dart';

/// One suggested edit as a flat row: category pill, original ->
/// replacement and explanation, with a check mark (keep the change) and a
/// cross (leave the original) at its end, the one that applies selected;
/// pressing the other one switches ([onToggle]). A hairline separates it
/// from the next row unless it is the last one ([divider]).
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
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final explanation = edit.explanation.trim();
    final subtitleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: palette.secondaryText,
    );

    Widget choice({
      required bool keep,
      required IconData icon,
      required String tooltip,
    }) {
      final selected = accepted == keep;
      return IconButton(
        key: Key(keep ? 'proofread_edit_accept' : 'proofread_edit_reject'),
        tooltip: tooltip,
        isSelected: selected,
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(
            selected
                ? (keep ? scheme.onPrimaryContainer : scheme.onSurface)
                : palette.secondaryText,
          ),
          backgroundColor: WidgetStatePropertyAll(
            selected
                ? (keep
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest)
                : Colors.transparent,
          ),
          side: WidgetStatePropertyAll(
            selected ? BorderSide.none : BorderSide(color: scheme.outline),
          ),
        ),
        icon: Icon(icon),
        // The chosen one stays chosen.
        onPressed: selected ? () {} : onToggle,
      );
    }

    final tile = Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Expanded(
              child: Opacity(
                // A rejected change reads as set aside.
                opacity: accepted ? 1 : 0.6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ProofreadCategoryChip(category: edit.category),
                    ),
                    ProofreadEditChange(
                      edit: edit,
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (explanation.isNotEmpty || !located)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
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
                  ],
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                choice(
                  keep: true,
                  icon: Icons.check_rounded,
                  tooltip: l10n.proofreadEditAccept,
                ),
                choice(
                  keep: false,
                  icon: Icons.close_rounded,
                  tooltip: l10n.proofreadEditReject,
                ),
              ],
            ),
          ],
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
