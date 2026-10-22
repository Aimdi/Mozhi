import 'dart:typed_data';

import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/phrasebook/models/phrase.dart';
import 'package:mozhi/phrasebook/models/phrase_draft.dart';
import 'package:translation_repository/translation_repository.dart'
    show LanguageCatalog;

/// A collection as a CSV file for Anki and spreadsheets ([PhrasebookCsv]'s
/// format, as History's "Export favorites" writes it): one row per phrase
/// with the phrase (front), its translation (back), the source and target
/// languages (English names), the date (`yyyy-MM-dd`) and the note, after
/// Anki's header lines, in UTF-8 with a byte order mark.
abstract final class CollectionCsv {
  /// The file's media type.
  static const String mimeType = PhrasebookCsv.mimeType;

  /// The rows of [phrases].
  static String encode(Iterable<Phrase> phrases) => PhrasebookCsv.encodeRows([
    for (final phrase in phrases)
      [
        phrase.text,
        phrase.translation,
        languageName(phrase.sourceCode),
        languageName(phrase.targetCode),
        PhrasebookCsv.date(phrase.createdAt),
        phrase.note,
      ],
  ]);

  /// The file of [phrases].
  static Uint8List bytes(Iterable<Phrase> phrases) =>
      PhrasebookCsv.textBytes(encode(phrases));

  /// The file name for the collection [name]: `mozhi-<name>.csv`, with
  /// what file systems refuse (and spaces) replaced by `-`.
  static String fileName(String name) {
    final slug = name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\s]+'), '-')
        .replaceAll(RegExp('-+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    final short = slug.length > 60 ? slug.substring(0, 60) : slug;
    return short.isEmpty ? 'mozhi-phrasebook.csv' : 'mozhi-$short.csv';
  }

  /// The English name of the language [code] (the code itself when the
  /// catalogue does not know it; empty for an unknown language).
  static String languageName(String code) =>
      code == Phrase.unknownLanguage ? '' : LanguageCatalog.nameOf(code);
}

/// How the rows of a CSV file become phrases (the import's preview): which
/// column holds the phrase and which its translation, whether the first
/// row is a header, and the languages of the two columns.
class CsvImportMapping {
  const new({
    required this.textColumn,
    required this.translationColumn,
    required this.sourceCode,
    required this.targetCode,
    this.hasHeader = false,
  });

  /// The mapping a file suggests: the first two columns (the phrase and its
  /// translation, as this app, Anki and most word lists write them), a
  /// header when the first row names them ([looksLikeHeader]), and the
  /// languages [sourceCode] and [targetCode].
  factory suggest(
    CsvTable table, {
    required String sourceCode,
    required String targetCode,
  }) => CsvImportMapping(
    textColumn: 0,
    translationColumn: table.columns > 1 ? 1 : 0,
    sourceCode: sourceCode,
    targetCode: targetCode,
    hasHeader: table.rows.isNotEmpty && looksLikeHeader(table.rows.first),
  );

  final int textColumn;
  final int translationColumn;
  final String sourceCode;
  final String targetCode;
  final bool hasHeader;

  /// Whether [row] looks like a header: its first two fields are words
  /// such as "Front"/"Back", "Text"/"Translation", or language names.
  static bool looksLikeHeader(List<String> row) {
    if (row.length < 2) return false;
    bool named(String value) {
      final key = value.trim().toLowerCase();
      return _headerWords.contains(key) ||
          (key.isNotEmpty && LanguageCatalog.byName(key) != null);
    }

    return named(row[0]) && named(row[1]);
  }

  static const _headerWords = {
    'front',
    'back',
    'text',
    'phrase',
    'word',
    'term',
    'source',
    'target',
    'translation',
    'meaning',
    'definition',
    'question',
    'answer',
  };

  /// Whether the mapping can import: two different columns.
  bool get isValid => textColumn != translationColumn;

  /// The phrases of [table]'s rows (the header left out; rows with an
  /// empty phrase or translation are skipped).
  List<PhraseDraft> drafts(CsvTable table) => [
    for (final row in hasHeader ? table.rows.skip(1) : table.rows)
      if (CsvTable.cell(row, textColumn).trim().isNotEmpty &&
          CsvTable.cell(row, translationColumn).trim().isNotEmpty)
        PhraseDraft(
          text: CsvTable.cell(row, textColumn).trim(),
          translation: CsvTable.cell(row, translationColumn).trim(),
          sourceCode: sourceCode,
          targetCode: targetCode,
        ),
  ];

  CsvImportMapping copyWith({
    int? textColumn,
    int? translationColumn,
    String? sourceCode,
    String? targetCode,
    bool? hasHeader,
  }) => CsvImportMapping(
    textColumn: textColumn ?? this.textColumn,
    translationColumn: translationColumn ?? this.translationColumn,
    sourceCode: sourceCode ?? this.sourceCode,
    targetCode: targetCode ?? this.targetCode,
    hasHeader: hasHeader ?? this.hasHeader,
  );
}
