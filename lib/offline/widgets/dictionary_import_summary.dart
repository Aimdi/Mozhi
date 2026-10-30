import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/dictionary_packs_state.dart';
import 'package:mozhi/offline/data/offline_model_error.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:translation_repository/translation_repository.dart'
    show DictionaryPackInfo;

/// What an import of dictionary packs from files did: one line per pack
/// (installed, already installed, a damaged file, a failure) and one for
/// the files that matched no pack. [nameOf] names a pack for display.
class DictionaryImportSummaryDialog extends StatelessWidget {
  const new({required this.outcome, required this.nameOf, super.key});

  final DictionaryImportOutcome outcome;
  final String Function(DictionaryPackInfo pack) nameOf;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final report = outcome.report;
    final failed = outcome.error != null;
    return AlertDialog(
      icon: Icon(
        report.installedAny ? Icons.download_done : Icons.info_outline,
      ),
      title: Text(
        failed
            ? l10n.offlineImportError
            : report.installedAny
            ? l10n.offlineDictionariesImportTitleDone
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
                  for (final entry in report.packs)
                    _line(context, entry, bidiIsolate(nameOf(entry.pack))),
                  if (report.unmatchedFiles.isNotEmpty)
                    _Line(
                      icon: Icons.help_outline,
                      color: colors.error,
                      text: l10n.offlineDictionariesImportUnmatched(
                        report.unmatchedFiles.length,
                      ),
                      files: report.unmatchedFiles,
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

  Widget _line(
    BuildContext context,
    DictionaryImportedPack entry,
    String name,
  ) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return switch (entry.status) {
      DictionaryImportStatus.installed => _Line(
        icon: Icons.check_circle_outline,
        color: colors.primary,
        text: l10n.offlineImportInstalled(name),
      ),
      DictionaryImportStatus.alreadyInstalled => _Line(
        icon: Icons.offline_pin_outlined,
        color: colors.primary,
        text: l10n.offlineImportAlreadyInstalled(name),
      ),
      DictionaryImportStatus.damaged => _Line(
        icon: Icons.gpp_bad_outlined,
        color: colors.error,
        text: l10n.offlineDictionariesImportDamaged(name),
        files: [entry.pack.fileName],
      ),
      DictionaryImportStatus.failed => _Line(
        icon: Icons.error_outline,
        color: colors.error,
        text: switch (OfflineModelError.of(entry.error ?? StateError(''))) {
          OfflineModelError(kind: OfflineModelErrorKind.space, :final space?) =>
            l10n.commonNotEnoughSpaceFor(
              name,
              formatStorageSize(l10n, space.requiredBytes),
              formatStorageSize(l10n, space.availableBytes),
            ),
          OfflineModelError(kind: OfflineModelErrorKind.storage) =>
            l10n.offlineErrorStorage(name),
          _ => l10n.offlineImportFailed(name),
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
        ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
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
