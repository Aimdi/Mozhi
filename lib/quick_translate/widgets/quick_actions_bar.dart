import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Copy / Listen / Open in app / Replace buttons of the quick translate
/// sheet. Null callbacks hide the button (Copy and Replace are shown but
/// disabled until [enabled]).
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
    final copyIcon = Icon(copied ? Icons.check : Icons.copy_outlined);
    final copyLabel = Text(
      copied ? l10n.quickTranslateCopied : l10n.commonCopy,
    );
    final canReplace = onReplace != null;

    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        ?listenButton,
        if (canReplace)
          OutlinedButton.icon(
            key: const Key('quick_translate_copy'),
            onPressed: enabled ? onCopy : null,
            icon: copyIcon,
            label: copyLabel,
          )
        else
          FilledButton.tonalIcon(
            key: const Key('quick_translate_copy'),
            onPressed: enabled ? onCopy : null,
            icon: copyIcon,
            label: copyLabel,
          ),
        if (onOpenInApp case final VoidCallback openInApp)
          TextButton.icon(
            key: const Key('quick_translate_open_in_app'),
            onPressed: openInApp,
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.quickTranslateOpenInApp),
          ),
        if (onReplace case final VoidCallback replace)
          Tooltip(
            message: l10n.quickTranslateReplaceTooltip,
            child: FilledButton.icon(
              key: const Key('quick_translate_replace'),
              onPressed: enabled ? replace : null,
              icon: const Icon(Icons.find_replace),
              label: Text(l10n.quickTranslateReplace),
            ),
          ),
      ],
    );
  }
}
