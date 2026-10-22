import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/practice/data/anki_export.dart';
import 'package:mozhi/practice/data/anki_notes.dart';
import 'package:mozhi/practice/widgets/practice_texts.dart';

/// The platform file operations the Anki export uses (a save dialog or a
/// download, the share sheet); replaceable in tests.
abstract final class PracticeExport {
  @visibleForTesting
  static DocumentFileService files = const PlatformDocumentFileService();
}

enum _Action { save, share }

/// Exports phrases for Anki ([AnkiExport], [ankiNotesOf]): a sheet lets
/// the user pick one of [collections] or all of them ([initialCollection]
/// first), says what the file holds and that it is not encrypted, then
/// saves it (a download on the web) or shares it. Nothing leaves the
/// device unless the user shares the file.
Future<void> showAnkiExport(
  BuildContext context, {
  required PhrasebookRepository phrasebook,
  required List<PhraseCollection> collections,
  required String appLanguage,
  String? initialCollection,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final files = PracticeExport.files;
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize
      ? null
      : box.localToGlobal(Offset.zero) & box.size;
  final choice = await showModalBottomSheet<(_Action, String?)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ExportSheet(
      collections: collections,
      initial: initialCollection,
      canShare: files.canShareFiles,
    ),
  );
  if (choice == null) return;
  final (action, collectionId) = choice;
  void say(String message) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  final collection = collections.where((c) => c.id == collectionId).firstOrNull;
  final fileName = AnkiExport.fileName(
    collection == null ? null : practiceCollectionName(l10n, collection),
  );
  try {
    final notes = await ankiNotesOf(
      phrasebook,
      appLanguage: appLanguage,
      nameOf: (collection) => practiceCollectionName(l10n, collection),
      collectionId: collectionId,
    );
    final bytes = AnkiExport.bytes(notes);
    switch (action) {
      case _Action.save:
        final saved = await files.saveFile(
          fileName: fileName,
          bytes: bytes,
          mimeType: AnkiExport.mimeType,
        );
        if (saved) say(l10n.practiceExportSaved(notes.length));
      case _Action.share:
        await files.shareFile(
          fileName: fileName,
          bytes: bytes,
          mimeType: AnkiExport.mimeType,
          origin: origin,
        );
    }
  } on ShareUnsupportedException {
    say(l10n.historyExportShareUnsupported);
  } on Object {
    say(l10n.practiceExportFailed);
  }
}

class _ExportSheet extends StatefulWidget {
  const new({required this.collections, required this.canShare, this.initial});

  final List<PhraseCollection> collections;
  final String? initial;
  final bool canShare;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  /// The collection's id, or '' for all.
  late String _selected = widget.initial ?? '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final collectionId = _selected.isEmpty ? null : _selected;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.practiceExport,
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
                    Icon(
                      Icons.lock_open_outlined,
                      size: 20,
                      color: colors.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.practiceExportNote,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              RadioGroup<String>(
                groupValue: _selected,
                onChanged: (value) => setState(() => _selected = value ?? ''),
                child: Column(
                  children: [
                    RadioListTile<String>(
                      key: const Key('practice_export_all'),
                      value: '',
                      title: Text(l10n.practiceExportAll),
                    ),
                    for (final collection in widget.collections)
                      RadioListTile<String>(
                        key: ValueKey('practice_export_${collection.id}'),
                        value: collection.id,
                        title: Text(practiceCollectionName(l10n, collection)),
                        subtitle: Text(
                          l10n.practiceCollectionPhrases(collection.length),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                key: const Key('practice_export_save'),
                leading: const Icon(Icons.file_download_outlined),
                title: Text(l10n.practiceExportSave),
                onTap: () =>
                    Navigator.of(context).pop((_Action.save, collectionId)),
              ),
              if (widget.canShare)
                ListTile(
                  key: const Key('practice_export_share'),
                  leading: const Icon(Icons.share_outlined),
                  title: Text(l10n.practiceExportShare),
                  onTap: () =>
                      Navigator.of(context).pop((_Action.share, collectionId)),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
