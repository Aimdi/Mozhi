import 'package:flutter/foundation.dart';
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
) {
  final l10n = context.l10n;
  return showCsvExport(
    context,
    fileName: PhrasebookCsv.fileName,
    bytes: () => PhrasebookCsv.bytes(entries),
    title: l10n.historyExportTitle(entries.length),
    note: l10n.historyExportNote,
    saved: l10n.historyExportSaved(entries.length),
    failed: l10n.historyExportFailed,
  );
}

/// Exports a CSV file named [fileName] (its [bytes], made once chosen): a
/// sheet with [title] and [note] (what the file holds, that it is not
/// encrypted) offers Save (a download on the web; [saved] confirms it) and
/// Share. [failed] says when neither worked. Also the phrasebook's export
/// of a collection.
Future<void> showCsvExport(
  BuildContext context, {
  required String fileName,
  required Uint8List Function() bytes,
  required String title,
  required String note,
  required String saved,
  required String failed,
}) async {
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
        _ExportSheet(title: title, note: note, canShare: files.canShareFiles),
  );
  if (choice == null) return;
  final data = bytes();
  void say(String message) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  try {
    switch (choice) {
      case _ExportChoice.save:
        final done = await files.saveFile(
          fileName: fileName,
          bytes: data,
          mimeType: PhrasebookCsv.mimeType,
        );
        if (done) say(saved);
      case _ExportChoice.share:
        await files.shareFile(
          fileName: fileName,
          bytes: data,
          mimeType: PhrasebookCsv.mimeType,
          origin: origin,
        );
    }
  } on ShareUnsupportedException {
    say(l10n.historyExportShareUnsupported);
  } on Object {
    say(failed);
  }
}

/// What the export makes, and Save / Share.
class _ExportSheet extends StatelessWidget {
  const new({required this.title, required this.note, required this.canShare});

  final String title;
  final String note;
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
                title,
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
                    note,
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
