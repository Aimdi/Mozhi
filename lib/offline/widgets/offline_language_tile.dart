import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// One offline language: name, native name, download state and the
/// download/delete action (or a progress indicator while one runs).
class OfflineLanguageTile extends StatelessWidget {
  const new({
    required this.language,
    required this.downloaded,
    required this.onDownload,
    required this.onDelete,
    this.pending,
    this.wifiOnly = true,
    this.enabled = true,
    super.key,
  });

  final OfflineLanguage language;
  final bool downloaded;
  final OfflineModelOperation? pending;
  final bool wifiOnly;

  /// False disables the actions (e.g. on platforms without the engine).
  final bool enabled;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final status = switch (pending) {
      OfflineModelOperation.download =>
        wifiOnly ? l10n.offlineDownloadingWifiOnly : l10n.offlineDownloading,
      OfflineModelOperation.delete => l10n.offlineDeleting,
      null => null,
    };
    final subtitle = status ?? language.nativeName;
    return ListTile(
      enabled: enabled,
      leading: Icon(
        downloaded ? Icons.offline_pin : Icons.translate,
        color: downloaded ? colors.primary : colors.onSurfaceVariant,
      ),
      title: Text(language.name),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: switch ((pending, downloaded)) {
        (OfflineModelOperation(), _) => SizedBox.square(
          dimension: 48,
          child: Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                semanticsLabel: status,
              ),
            ),
          ),
        ),
        (null, true) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusBadge(
              label: l10n.offlineDownloadedBadge,
              color: colors.success,
              icon: Icons.check,
            ),
            IconButton(
              tooltip: l10n.offlineDeleteTooltip(language.name),
              icon: const Icon(Icons.delete_outline),
              onPressed: enabled ? onDelete : null,
            ),
          ],
        ),
        (null, false) => IconButton(
          tooltip: l10n.offlineDownloadTooltip(language.name),
          icon: const Icon(Icons.download_outlined),
          onPressed: enabled ? onDownload : null,
        ),
      },
    );
  }
}

/// Asks before deleting [language]'s model; true when confirmed.
Future<bool> confirmDeleteOfflineLanguage(
  BuildContext context,
  OfflineLanguage language,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => DeleteOfflineLanguageDialog(language: language),
  );
  return confirmed ?? false;
}

class DeleteOfflineLanguageDialog extends StatelessWidget {
  const new({required this.language, super.key});

  final OfflineLanguage language;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.delete_outline),
      title: Text(l10n.offlineDeleteTitle(language.name)),
      content: Text(l10n.offlineDeleteBody(language.name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: colors.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.commonDelete),
        ),
      ],
    );
  }
}
