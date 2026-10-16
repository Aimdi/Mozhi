import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';

/// One offline language as a flat row: its avatar, name, native name (or
/// what is happening) and a "follow button" style pill: an inverse
/// "Download" pill for missing models, an outlined "Downloaded" pill
/// (that turns into "Delete" on hover/focus and deletes) for downloaded
/// ones, and accent progress while an operation runs.
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
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final status = switch (pending) {
      OfflineModelOperation.download =>
        wifiOnly ? l10n.offlineDownloadingWifiOnly : l10n.offlineDownloading,
      OfflineModelOperation.delete => l10n.offlineDeleting,
      null => null,
    };
    final subtitle = status ?? language.nativeName;
    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 12),
      minVerticalPadding: 12,
      leading: _Avatar(code: language.code, downloaded: downloaded),
      title: Text(
        language.name,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: status != null
                    ? theme.colorScheme.primary
                    : palette.secondaryText,
              ),
            ),
      trailing: switch ((pending, downloaded)) {
        (OfflineModelOperation(), _) => SizedBox.square(
          dimension: 48,
          child: Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.primary,
                backgroundColor: palette.hairline,
                semanticsLabel: status,
              ),
            ),
          ),
        ),
        (null, true) => _DownloadedPill(
          tooltip: l10n.offlineDeleteTooltip(language.name),
          onPressed: enabled ? onDelete : null,
        ),
        (null, false) => Tooltip(
          message: l10n.offlineDownloadTooltip(language.name),
          child: FilledButton(
            key: const Key('offline_download_pill'),
            style: _pillStyle(
              FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.onSurface,
                foregroundColor: theme.colorScheme.surface,
              ),
            ),
            onPressed: enabled ? onDownload : null,
            child: Text(l10n.offlineDownloadAction),
          ),
        ),
      },
    );
  }
}

ButtonStyle _pillStyle(ButtonStyle base) => base.copyWith(
  shape: const WidgetStatePropertyAll(StadiumBorder()),
  minimumSize: const WidgetStatePropertyAll(Size(88, 36)),
  tapTargetSize: MaterialTapTargetSize.padded,
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
  textStyle: const WidgetStatePropertyAll(
    TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
  ),
);

/// The language avatar with a small "offline pin" badge once downloaded.
class _Avatar extends StatelessWidget {
  const new({required this.code, required this.downloaded});

  final String code;
  final bool downloaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          LanguageAvatar(code: code),
          if (downloaded)
            PositionedDirectional(
              end: -2,
              bottom: -2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1.5),
                  child: Icon(
                    Icons.offline_pin,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// X's "Following" pill: outlined "Downloaded" that reads "Delete" in the
/// error colour while hovered or focused, and deletes when pressed.
class _DownloadedPill extends StatefulWidget {
  const new({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<_DownloadedPill> createState() => _DownloadedPillState();
}

class _DownloadedPillState extends State<_DownloadedPill> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final danger = widget.onPressed != null && (_hovered || _focused);
    final error = theme.colorScheme.error;
    return Tooltip(
      message: widget.tooltip,
      child: OutlinedButton(
        key: const Key('offline_downloaded_pill'),
        onHover: (value) => setState(() => _hovered = value),
        onFocusChange: (value) => setState(() => _focused = value),
        style: _pillStyle(
          OutlinedButton.styleFrom(
            foregroundColor: danger ? error : theme.colorScheme.onSurface,
            backgroundColor: danger ? error.withValues(alpha: 0.08) : null,
            side: BorderSide(
              color: danger ? error.withValues(alpha: 0.5) : palette.hairline,
            ),
          ),
        ),
        onPressed: widget.onPressed,
        child: Text(danger ? l10n.commonDelete : l10n.offlineDownloadedBadge),
      ),
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AlertDialog(
      title: Text(
        l10n.offlineDeleteTitle(language.name),
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
      content: Text(
        l10n.offlineDeleteBody(language.name),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: AppPalette.of(context).secondaryText,
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: colors.onError,
            backgroundColor: colors.error,
            shape: const StadiumBorder(),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.commonDelete),
        ),
      ],
    );
  }
}
