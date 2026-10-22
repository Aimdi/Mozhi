import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/widgets/dictionary_language_picker.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/collection_csv.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// The file picker of the CSV import (the document translator's),
/// replaceable in tests.
abstract final class PhrasebookFiles {
  @visibleForTesting
  static DocumentFileService files = const PlatformDocumentFileService();
}

/// The extensions the import offers.
const csvImportExtensions = ['csv', 'tsv', 'txt'];

/// Imports a CSV file into the user's [collection]: picks the file
/// ([PhrasebookFiles.files]), reads it on the device ([PhrasebookCsv.parse])
/// and shows [CsvImportDialog] (a preview, the two columns, a header row,
/// the languages: [sourceCode] → [targetCode] to start with). Imports
/// what the dialog says and reports how many phrases were added; a
/// collection without languages takes the import's.
Future<void> importCsvInto(
  BuildContext context, {
  required PhrasebookRepository repository,
  required PhraseCollection collection,
  required String sourceCode,
  required String targetCode,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String message) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  final PickedFile? file;
  try {
    file = await PhrasebookFiles.files.pickFile(
      extensions: csvImportExtensions,
    );
  } on Object {
    say(l10n.phrasebookImportFailed);
    return;
  }
  if (file == null || !context.mounted) return;
  final table = PhrasebookCsv.parse(
    utf8.decode(file.bytes, allowMalformed: true),
  );
  if (table.rows.isEmpty) {
    say(l10n.phrasebookImportEmpty);
    return;
  }
  final mapping = await showDialog<CsvImportMapping>(
    context: context,
    builder: (_) => CsvImportDialog(
      fileName: file!.name,
      table: table,
      initial: CsvImportMapping.suggest(
        table,
        sourceCode: sourceCode,
        targetCode: targetCode,
      ),
    ),
  );
  if (mapping == null) return;
  try {
    final added = await repository.importPhrases(
      collection.id,
      mapping.drafts(table),
    );
    if (collection.sourceCode == null && collection.targetCode == null) {
      await repository.setCollectionLanguages(
        collection.id,
        sourceCode: mapping.sourceCode,
        targetCode: mapping.targetCode,
      );
    }
    say(l10n.phrasebookImportDone(added));
  } on Object {
    say(l10n.phrasebookSaveFailed);
  }
}

/// The import's preview: which column holds the phrase and which its
/// translation ("Column 2: Olá", from the first row), whether the first
/// row is a header, the two languages, and the first phrases as they will
/// be imported. Pops the [CsvImportMapping] to import with.
class CsvImportDialog extends StatefulWidget {
  const new({
    required this.fileName,
    required this.table,
    required this.initial,
    super.key,
  });

  final String fileName;
  final CsvTable table;
  final CsvImportMapping initial;

  /// How many phrases the preview shows.
  static const previewRows = 5;

  @override
  State<CsvImportDialog> createState() => _CsvImportDialogState();
}

class _CsvImportDialogState extends State<CsvImportDialog> {
  late CsvImportMapping _mapping = widget.initial;

  Language _language(String code) =>
      LanguageCatalog.byCode(code) ??
      Language(code: code, name: phrasebookLanguageName(context.l10n, code));

  Future<void> _pickLanguage({required bool source}) async {
    final l10n = context.l10n;
    final picked = await showDictionaryLanguagePicker(
      context,
      title: source ? l10n.phrasebookImportFrom : l10n.phrasebookImportTo,
      languages: LanguageCatalog.all,
      selected: _language(source ? _mapping.sourceCode : _mapping.targetCode),
    );
    if (picked == null || !mounted) return;
    setState(
      () => _mapping = source
          ? _mapping.copyWith(sourceCode: picked.code)
          : _mapping.copyWith(targetCode: picked.code),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final table = widget.table;
    final columns = table.columns;
    final first = table.rows.first;
    final drafts = _mapping.drafts(table);
    final valid = _mapping.isValid && drafts.isNotEmpty;

    DropdownMenuItem<int> column(int index) {
      final sample = CsvTable.cell(first, index).trim();
      return DropdownMenuItem(
        value: index,
        child: Text(
          l10n.phrasebookImportColumn(
            index + 1,
            sample.length > 40 ? '${sample.substring(0, 40)}…' : sample,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    Widget language({required bool source}) {
      final code = source ? _mapping.sourceCode : _mapping.targetCode;
      return ListTile(
        key: Key(source ? 'phrasebook_import_from' : 'phrasebook_import_to'),
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.translate),
        title: Text(
          source ? l10n.phrasebookImportFrom : l10n.phrasebookImportTo,
        ),
        subtitle: Text(phrasebookLanguageName(l10n, code)),
        trailing: const Icon(Icons.arrow_drop_down),
        onTap: () => unawaited(_pickLanguage(source: source)),
      );
    }

    return AlertDialog(
      key: const Key('phrasebook_import_dialog'),
      title: Text(l10n.phrasebookImportTitle),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text(
              l10n.phrasebookImportFile(widget.fileName, table.rows.length),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            DropdownButtonFormField<int>(
              key: const Key('phrasebook_import_text_column'),
              initialValue: _mapping.textColumn,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.phrasebookImportPhraseColumn,
              ),
              items: [for (var i = 0; i < columns; i++) column(i)],
              onChanged: (value) => setState(
                () => _mapping = _mapping.copyWith(textColumn: value),
              ),
            ),
            DropdownButtonFormField<int>(
              key: const Key('phrasebook_import_translation_column'),
              initialValue: _mapping.translationColumn,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.phrasebookImportTranslationColumn,
                errorText: _mapping.isValid
                    ? null
                    : l10n.phrasebookImportSameColumn,
              ),
              items: [for (var i = 0; i < columns; i++) column(i)],
              onChanged: (value) => setState(
                () => _mapping = _mapping.copyWith(translationColumn: value),
              ),
            ),
            SwitchListTile(
              key: const Key('phrasebook_import_header'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.phrasebookImportHeader),
              value: _mapping.hasHeader,
              onChanged: (value) => setState(
                () => _mapping = _mapping.copyWith(hasHeader: value),
              ),
            ),
            language(source: true),
            language(source: false),
            if (_mapping.isValid && drafts.isNotEmpty) ...[
              Semantics(
                header: true,
                child: Text(
                  l10n.phrasebookImportPreview,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              for (final draft in drafts.take(CsvImportDialog.previewRows))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: draft.text),
                        const TextSpan(text: '  →  '),
                        TextSpan(
                          text: draft.translation,
                          style: TextStyle(color: theme.colorScheme.primary),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            Text(
              l10n.phrasebookImportNote,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('phrasebook_import_confirm'),
          onPressed: valid ? () => Navigator.of(context).pop(_mapping) : null,
          child: Text(l10n.phrasebookImportAction(valid ? drafts.length : 0)),
        ),
      ],
    );
  }
}
