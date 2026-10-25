import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_state.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/offline/data/offline_model_import.dart';
import 'package:mozhi/platform/free_space.dart';

/// "{source} → {target}" for a model direction, laid out in the UI
/// direction (the names are bidi isolates).
String offlineDirectionLabel(
  AppLocalizations l10n,
  OfflineLanguage source,
  OfflineLanguage target,
) => l10n.offlineModelDirection(
  bidiIsolate(source.name),
  bidiIsolate(target.name),
);

/// What an import from files did: one line per direction (installed,
/// already installed, missing files, a damaged file, a failure) and one for
/// the files that matched no model.
class OfflineImportSummaryDialog extends StatelessWidget {
  const new({required this.outcome, super.key});

  final OfflineImportOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final failed = outcome.error != null;
    final needsFiles = outcome.entries.any(
      (entry) =>
          entry.status == OfflineImportStatus.incomplete ||
          entry.status == OfflineImportStatus.damaged,
    );
    return AlertDialog(
      icon: Icon(
        outcome.installedAny ? Icons.download_done : Icons.info_outline,
      ),
      title: Text(
        failed
            ? l10n.offlineImportError
            : outcome.installedAny
            ? l10n.offlineImportTitleDone
            : l10n.offlineImportTitleNothing,
        style: theme.textTheme.titleLarge,
      ),
      content: failed
          ? null
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  for (final entry in outcome.entries) _EntryLine(entry: entry),
                  if (outcome.unmatchedFiles.isNotEmpty)
                    _Line(
                      icon: Icons.help_outline,
                      color: colors.error,
                      text: l10n.offlineImportUnmatched(
                        outcome.unmatchedFiles.length,
                      ),
                      files: outcome.unmatchedFiles,
                    ),
                  if (needsFiles)
                    Text(
                      l10n.offlineImportMissingHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppPalette.of(context).secondaryText,
                      ),
                    ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

class _EntryLine extends StatelessWidget {
  const new({required this.entry});

  final OfflineImportEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final direction = offlineDirectionLabel(l10n, entry.source, entry.target);
    final missing = entry.missingFiles;
    return switch (entry.status) {
      OfflineImportStatus.installed => _Line(
        icon: Icons.check_circle_outline,
        color: colors.primary,
        text: l10n.offlineImportInstalled(direction),
      ),
      OfflineImportStatus.alreadyInstalled => _Line(
        icon: Icons.offline_pin_outlined,
        color: colors.primary,
        text: l10n.offlineImportAlreadyInstalled(direction),
      ),
      OfflineImportStatus.incomplete => _Line(
        icon: Icons.rule,
        color: colors.error,
        text: l10n.offlineImportMissing(missing.length, direction),
        files: missing,
      ),
      OfflineImportStatus.damaged => _Line(
        icon: Icons.gpp_bad_outlined,
        color: colors.error,
        text: l10n.offlineImportDamaged(direction),
        files: missing,
      ),
      OfflineImportStatus.failed => _Line(
        icon: Icons.error_outline,
        color: colors.error,
        text: switch (entry.error) {
          OfflineModelError(kind: OfflineModelErrorKind.space, :final space?) =>
            l10n.commonNotEnoughSpaceFor(
              direction,
              formatStorageSize(l10n, space.requiredBytes),
              formatStorageSize(l10n, space.availableBytes),
            ),
          OfflineModelError(kind: OfflineModelErrorKind.storage) =>
            l10n.offlineErrorStorage(direction),
          _ => l10n.offlineImportFailed(direction),
        },
      ),
    };
  }
}

/// An icon, a message and, below it, file names.
class _Line extends StatelessWidget {
  const new({
    required this.icon,
    required this.color,
    required this.text,
    this.files = const [],
  });

  final IconData icon;
  final Color color;
  final String text;
  final List<String> files;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Icon(icon, size: 20, color: color),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(text, style: theme.textTheme.bodyMedium),
              for (final file in files)
                Text(
                  file,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: AppPalette.of(context).secondaryText,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
