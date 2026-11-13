import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Above a saved entry (`DictionaryState.saved`: kept by the history, or
/// looked up a little earlier): says that it was not asked for again,
/// with "Refresh" ([onRefresh], asks the AI again; hidden when null).
class DictionarySavedNotice extends StatelessWidget {
  const new({this.onRefresh, super.key});

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return Wrap(
      key: const Key('dictionary_saved_notice'),
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          l10n.dictionarySavedEntry,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: muted),
        ),
        if (onRefresh case final onRefresh?)
          Tooltip(
            message: l10n.dictionaryRefreshTooltip,
            child: TextButton.icon(
              key: const Key('dictionary_refresh'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.dictionaryRefresh),
            ),
          ),
      ],
    );
  }
}
