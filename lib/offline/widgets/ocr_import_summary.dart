import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The lines that summarise an import of text recognition data:
/// installed, already installed, damaged and failed languages (named by
/// [nameOf], given a language code) and the files that are no recognition
/// data.
List<String> ocrImportSummaryLines(
  AppLocalizations l10n,
  OcrImportReport report,
  String Function(String code) nameOf,
) => [
  if (report.error != null) l10n.offlineImportError,
  for (final code in report.installed)
    l10n.offlineOcrImportInstalled(nameOf(code)),
  for (final code in report.alreadyInstalled)
    l10n.offlineOcrImportAlreadyInstalled(nameOf(code)),
  for (final code in report.damaged) l10n.offlineOcrImportDamaged(nameOf(code)),
  for (final code in report.failed) l10n.offlineOcrImportFailed(nameOf(code)),
  if (report.unmatchedFiles.isNotEmpty)
    l10n.offlineOcrImportUnmatched(report.unmatchedFiles.length),
];

/// What an import of text recognition data did.
class OcrImportSummaryDialog extends StatelessWidget {
  const new({required this.report, required this.nameOf, super.key});

  final OcrImportReport report;
  final String Function(String code) nameOf;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final lines = ocrImportSummaryLines(l10n, report, nameOf);
    return AlertDialog(
      icon: const Icon(Icons.file_open_outlined),
      title: Text(
        report.installed.isEmpty
            ? l10n.offlineImportTitleNothing
            : l10n.offlineOcrImportTitleDone,
        style: theme.textTheme.titleLarge,
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            for (final line in lines)
              Text(
                line,
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
