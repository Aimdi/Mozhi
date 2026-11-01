import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The quick improve sheet's toolbar, laid out like the quick translate
/// one (`QuickActionsBar`): quiet accent actions (Copy, Retry) at the
/// start and the pill actions (Open in Proofread, Replace) at the end.
///
/// Copy needs [canCopy], Replace [canReplace]; Retry is disabled without
/// [onRetry]. A null [onReplace] or [onOpenInProofread] hides that button
/// (Replace only exists for an editable selection).
class QuickImproveActionsBar extends StatelessWidget {
  const new({
    required this.canCopy,
    required this.onCopy,
    this.copied = false,
    this.onRetry,
    this.onOpenInProofread,
    this.onReplace,
    this.canReplace = false,
    super.key,
  });

  /// An improved text is shown.
  final bool canCopy;
  final VoidCallback onCopy;

  /// Shows the "Copied" confirmation on the copy button.
  final bool copied;

  /// Proofreads again; null disables the button.
  final VoidCallback? onRetry;
  final VoidCallback? onOpenInProofread;

  /// Replace the selection in the calling app; null hides the button.
  final VoidCallback? onReplace;

  /// Whether Replace is enabled (an improved text that changes something).
  final bool canReplace;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = AppPalette.of(context);

    return Row(
      children: [
        XActionButton(
          key: const Key('quick_improve_copy'),
          icon: Icons.copy_outlined,
          activeIcon: Icons.check,
          active: copied,
          activeColor: palette.success,
          tooltip: copied ? l10n.quickTranslateCopied : l10n.commonCopy,
          label: copied ? l10n.quickTranslateCopied : l10n.commonCopy,
          onPressed: canCopy ? onCopy : null,
        ),
        XActionButton(
          key: const Key('quick_improve_retry'),
          icon: Icons.refresh,
          tooltip: l10n.quickImproveRetryTooltip,
          label: l10n.commonRetry,
          onPressed: onRetry,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (onOpenInProofread case final VoidCallback open)
                OutlinedButton(
                  key: const Key('quick_improve_open_in_proofread'),
                  onPressed: open,
                  child: Text(l10n.quickImproveOpenInProofread),
                ),
              if (onReplace case final VoidCallback replace)
                Tooltip(
                  message: l10n.quickImproveReplaceTooltip,
                  child: FilledButton(
                    key: const Key('quick_improve_replace'),
                    onPressed: canReplace ? replace : null,
                    child: Text(l10n.quickTranslateReplace),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
