import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The platform file operations the phrasebook export uses (the document
/// translator's: a save dialog or download, the share sheet); replaceable
/// in tests.
abstract final class PhrasebookExport {
  @visibleForTesting
  static DocumentFileService files = const PlatformDocumentFileService();
}

enum _ExportChoice { save, share }

/// Exports [entries] (the favourites on screen) as a CSV file for Anki and
/// spreadsheets ([PhrasebookCsv]): a sheet says what the file holds and
/// that it is not encrypted, then saves it (a download on the web) or
/// shares it. Nothing leaves the device unless the user shares the file.
Future<void> showPhrasebookExport(
  BuildContext context,
  List<HistoryEntry> entries,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final files = PhrasebookExport.files;
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize
      ? null
      : box.localToGlobal(Offset.zero) & box.size;
  final choice = await showModalBottomSheet<_ExportChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) =>
        _ExportSheet(count: entries.length, canShare: files.canShareFiles),
  );
  if (choice == null) return;
  final bytes = PhrasebookCsv.bytes(entries);
  void say(String message) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  try {
    switch (choice) {
      case _ExportChoice.save:
        final saved = await files.saveFile(
          fileName: PhrasebookCsv.fileName,
          bytes: bytes,
          mimeType: PhrasebookCsv.mimeType,
        );
        if (saved) say(l10n.historyExportSaved(entries.length));
      case _ExportChoice.share:
        await files.shareFile(
          fileName: PhrasebookCsv.fileName,
          bytes: bytes,
          mimeType: PhrasebookCsv.mimeType,
          origin: origin,
        );
    }
  } on ShareUnsupportedException {
    say(l10n.historyExportShareUnsupported);
  } on Object {
    say(l10n.historyExportFailed);
  }
}

/// What the export makes, and Save / Share.
class _ExportSheet extends StatelessWidget {
  const new({required this.count, required this.canShare});

  final int count;
  final bool canShare;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(
                l10n.historyExportTitle(count),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_open_outlined, size: 20, color: colors.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.historyExportNote,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            key: const Key('history_export_save'),
            leading: const Icon(Icons.file_download_outlined),
            title: Text(l10n.historyExportSave),
            onTap: () => Navigator.of(context).pop(_ExportChoice.save),
          ),
          if (canShare)
            ListTile(
              key: const Key('history_export_share'),
              leading: const Icon(Icons.share_outlined),
              title: Text(l10n.historyExportShare),
              onTap: () => Navigator.of(context).pop(_ExportChoice.share),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
