import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The quick translate sheet's X compose-style toolbar: quiet accent
/// actions (Listen, Copy) at the start and the pill actions (Open in app,
/// Replace) at the end. Copy and Replace are disabled until [enabled]; a
/// null [listenButton], [onReplace] or [onOpenInApp] hides that button.
class QuickActionsBar extends StatelessWidget {
  const new({
    required this.enabled,
    required this.onCopy,
    this.copied = false,
    this.listenButton,
    this.onReplace,
    this.onOpenInApp,
    super.key,
  });

  /// A finished translation is available.
  final bool enabled;
  final VoidCallback onCopy;

  /// Shows the "Copied" confirmation on the copy button.
  final bool copied;

  /// Usually a `QuickListenButton`; null hides it.
  final Widget? listenButton;

  /// Replace the selection in the calling app; null hides the button.
  final VoidCallback? onReplace;
  final VoidCallback? onOpenInApp;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = AppPalette.of(context);

    return Row(
      children: [
        ?listenButton,
        XActionButton(
          key: const Key('quick_translate_copy'),
          icon: Icons.copy_outlined,
          activeIcon: Icons.check,
          active: copied,
          activeColor: palette.success,
          tooltip: copied ? l10n.quickTranslateCopied : l10n.commonCopy,
          label: copied ? l10n.quickTranslateCopied : l10n.commonCopy,
          onPressed: enabled ? onCopy : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (onOpenInApp case final VoidCallback openInApp)
                OutlinedButton(
                  key: const Key('quick_translate_open_in_app'),
                  onPressed: openInApp,
                  child: Text(l10n.quickTranslateOpenInApp),
                ),
              if (onReplace case final VoidCallback replace)
                Tooltip(
                  message: l10n.quickTranslateReplaceTooltip,
                  child: FilledButton(
                    key: const Key('quick_translate_replace'),
                    onPressed: enabled ? replace : null,
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
