import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/offline_model_details.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;

/// One offline language as a flat row: its avatar, name, native name and
/// size (or what is happening) and a "follow button" style pill: an inverse
/// "Download" pill for missing models, an outlined "Downloaded" pill (that
/// turns into "Delete" on hover/focus and deletes) for downloaded ones, an
/// "Update" pill plus a delete button when a newer model exists, nothing
/// for built-in languages, and accent progress while an operation runs:
/// with [onCancel], a running download or update also shows Cancel next to
/// its progress ([cancelling]: being stopped). With [onShowFiles], tapping
/// the row shows the files to download by hand.
class OfflineLanguageTile extends StatelessWidget {
  const new({
    required this.language,
    required this.downloaded,
    required this.onDownload,
    required this.onDelete,
    this.pending,
    this.progress,
    this.downloadSize,
    this.installedSize,
    this.outdated = false,
    this.builtIn = false,
    this.enabled = true,
    this.onShowFiles,
    this.onCancel,
    this.cancelling = false,
    super.key,
  });

  final OfflineLanguage language;
  final bool downloaded;
  final OfflineModelOperation? pending;

  /// Fraction (0 to 1) of a running download or update, when known.
  final double? progress;

  /// Bytes to download (both directions), when known.
  final int? downloadSize;

  /// Bytes on this device, when known.
  final int? installedSize;

  /// A newer model exists: offers "Update" (which calls [onDownload]).
  final bool outdated;

  /// Works without a download (English): no actions.
  final bool builtIn;

  /// False disables the actions (e.g. on platforms without the engine).
  final bool enabled;

  /// Downloads or, when [outdated], updates the language.
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  /// Shows the language's files for a manual download (the row's tap).
  final VoidCallback? onShowFiles;

  /// Cancels the running download or update; null: no Cancel.
  final VoidCallback? onCancel;

  /// The running download or update is being cancelled (Cancel is
  /// disabled until it has stopped).
  final bool cancelling;

  String? _status(AppLocalizations l10n) {
    final percent = progress == null ? null : (progress! * 100).floor();
    if (cancelling && pending != OfflineModelOperation.delete) {
      return l10n.offlineCancelling;
    }
    return switch (pending) {
      OfflineModelOperation.download =>
        percent == null
            ? l10n.offlineDownloading
            : l10n.offlineDownloadingProgress(percent),
      OfflineModelOperation.update =>
        percent == null
            ? l10n.offlineUpdating
            : l10n.offlineUpdatingProgress(percent),
      OfflineModelOperation.delete => l10n.offlineDeleting,
      null => null,
    };
  }

  String? _details(AppLocalizations l10n) {
    final size = switch (this) {
      OfflineLanguageTile(builtIn: true) => l10n.offlineBuiltIn,
      OfflineLanguageTile(outdated: true, :final downloadSize?) =>
        l10n.offlineUpdateAvailable(formatStoredSize(l10n, downloadSize)),
      OfflineLanguageTile(downloaded: true, :final installedSize?) =>
        l10n.offlineInstalledSize(formatStoredSize(l10n, installedSize)),
      OfflineLanguageTile(downloaded: false, :final downloadSize?)
          when downloadSize > 0 =>
        l10n.offlineDownloadSize(formatStoredSize(l10n, downloadSize)),
      _ => null,
    };
    // A language that goes one way only says which way.
    final direction = switch (language.direction) {
      OfflineLanguageDirection.both => null,
      OfflineLanguageDirection.intoOnly => l10n.offlineDirectionIntoOnly(
        language.name,
      ),
      OfflineLanguageDirection.fromOnly => l10n.offlineDirectionFromOnly(
        language.name,
      ),
    };
    final parts = [?language.nativeName, ?direction, ?size];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final status = _status(l10n);
    final subtitle = status ?? _details(l10n);
    final accent = status != null || (outdated && pending == null);
    final tile = ListTile(
      enabled: enabled,
      onTap: onShowFiles,
      contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 12),
      minVerticalPadding: 12,
      leading: _Avatar(code: language.code, downloaded: downloaded),
      title: Text(language.name, style: theme.textTheme.titleSmall),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accent
                    ? theme.colorScheme.primary
                    : palette.secondaryText,
              ),
            ),
      trailing: switch ((pending, downloaded)) {
        (OfflineModelOperation.download || OfflineModelOperation.update, _)
            when onCancel != null =>
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Progress(value: progress, label: status),
              OfflineCancelDownloadButton(
                language: language.name,
                onPressed: enabled && !cancelling ? onCancel : null,
              ),
            ],
          ),
        (OfflineModelOperation(), _) => _Progress(
          value: progress,
          label: status,
        ),
        _ when builtIn => null,
        (null, true) when outdated => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _InversePill(
              key: const Key('offline_update_pill'),
              label: l10n.offlineUpdateAction,
              tooltip: l10n.offlineUpdateTooltip(language.name),
              onPressed: enabled ? onDownload : null,
            ),
            IconButton(
              tooltip: l10n.offlineDeleteTooltip(language.name),
              icon: const Icon(Icons.delete_outline),
              onPressed: enabled ? onDelete : null,
            ),
          ],
        ),
        (null, true) => _DownloadedPill(
          tooltip: l10n.offlineDeleteTooltip(language.name),
          onPressed: enabled ? onDelete : null,
        ),
        (null, false) => _InversePill(
          key: const Key('offline_download_pill'),
          label: l10n.offlineDownloadAction,
          tooltip: l10n.offlineDownloadTooltip(language.name),
          onPressed: enabled ? onDownload : null,
        ),
      },
    );
    return onShowFiles == null
        ? tile
        : Semantics(onTapHint: l10n.offlineManualHint, child: tile);
  }
}

/// The accent progress ring of a running operation, in a 48 dp square.
class _Progress extends StatelessWidget {
  const new({required this.value, required this.label});

  /// Fraction done (null: indeterminate).
  final double? value;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: 48,
      child: Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(
            value: value,
            strokeWidth: 2.5,
            color: theme.colorScheme.primary,
            backgroundColor: AppPalette.of(context).hairline,
            semanticsLabel: label,
          ),
        ),
      ),
    );
  }
}

/// "Cancel" for a running offline download: a 48 dp text button whose
/// tooltip and screen reader label say which download it stops
/// ("Cancel downloading German"); [onPressed] null disables it.
class OfflineCancelDownloadButton extends StatelessWidget {
  const new({required this.language, required this.onPressed, super.key});

  /// The name of the language being downloaded.
  final String language;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = l10n.offlineCancelDownloadTooltip(language);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        enabled: onPressed != null,
        onTap: onPressed,
        child: TextButton(
          key: const Key('offline_cancel_download'),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          onPressed: onPressed,
          child: Text(l10n.commonCancel),
        ),
      ),
    );
  }
}

/// X's inverse "Follow" pill (on-surface background).
class _InversePill extends StatelessWidget {
  const new({
    required this.label,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: FilledButton(
        // The theme's filled button is the inverse pill.
        style: _pillStyle(const ButtonStyle()),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// The theme's pill buttons, compact for a list row (the touch target
/// stays 48 dp).
ButtonStyle _pillStyle(ButtonStyle base) => base.copyWith(
  minimumSize: const WidgetStatePropertyAll(Size(88, 36)),
  tapTargetSize: MaterialTapTargetSize.padded,
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
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
              color: danger
                  ? error.withValues(alpha: 0.5)
                  : theme.colorScheme.outline,
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
  OfflineLanguage language, {
  String? body,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) =>
        DeleteOfflineLanguageDialog(language: language, body: body),
  );
  return confirmed ?? false;
}

class DeleteOfflineLanguageDialog extends StatelessWidget {
  const new({required this.language, this.body, super.key});

  final OfflineLanguage language;

  /// What stops working; defaults to offline translation's explanation.
  final String? body;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AlertDialog(
      title: Text(
        l10n.offlineDeleteTitle(language.name),
        style: theme.textTheme.titleLarge,
      ),
      content: Text(
        body ?? l10n.offlineDeleteBody(language.name),
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
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.commonDelete),
        ),
      ],
    );
  }
}
