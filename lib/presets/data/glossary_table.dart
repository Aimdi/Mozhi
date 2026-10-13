import 'package:mozhi/presets/models/glossary.dart';

/// Delimited-text formats for glossary terms.
enum GlossaryTableFormat {
  csv(',', 'csv', 'text/csv'),
  tsv('\t', 'tsv', 'text/tab-separated-values');

  new(this.delimiter, this.extension, this.mimeType);

  final String delimiter;
  final String extension;
  final String mimeType;
}

/// Terms read by [GlossaryTable.parse] plus the number of non-empty rows that
/// could not be used (missing source or target).
typedef GlossaryTableParse = ({List<GlossaryTerm> terms, int skipped});

/// Reads and writes glossary terms as CSV / TSV.
///
/// Columns: source, target, note (optional), case sensitive (optional). A
/// header row is optional; when present, columns may come in any order and
/// are recognised by name (`source`/`term`, `target`/`translation`,
/// `note`/`comment`, `case_sensitive`/`match case`). Fields may be quoted
/// with `"` (`""` escapes a quote, quoted fields may span lines); unquoted
/// fields are trimmed.
abstract final class GlossaryTable {
  /// Parses [text]. [delimiter] defaults to [detectDelimiter].
  static GlossaryTableParse parse(String text, {String? delimiter}) {
    final rows = splitRows(text, delimiter ?? detectDelimiter(text));
    if (rows.isEmpty) return (terms: const [], skipped: 0);
    var columns = _headerColumns(rows.first);
    final dataRows = columns == null ? rows : rows.skip(1);
    columns ??= const _Columns(source: 0, target: 1, note: 2, caseFlag: 3);
    final terms = <GlossaryTerm>[];
    var skipped = 0;
    for (final row in dataRows) {
      final term = GlossaryTerm(
        source: _cell(row, columns.source),
        target: _cell(row, columns.target),
        note: _cell(row, columns.note),
        caseSensitive: _isTrue(_cell(row, columns.caseFlag)),
      ).trimmed();
      if (term.isValid) {
        terms.add(term);
      } else {
        skipped++;
      }
    }
    return (terms: List.unmodifiable(terms), skipped: skipped);
  }

  /// Writes [terms] with a header row (`source,target,note,case_sensitive`)
  /// unless [header] is false. Fields are quoted when needed.
  static String format(
    Iterable<GlossaryTerm> terms, {
    GlossaryTableFormat format = GlossaryTableFormat.csv,
    bool header = true,
  }) {
    final d = format.delimiter;
    final lines = <String>[
      if (header) ['source', 'target', 'note', 'case_sensitive'].join(d),
      for (final term in terms)
        [
          term.source,
          term.target,
          term.note,
          if (term.caseSensitive) 'true' else 'false',
        ].map((field) => _quote(field, d)).join(d),
    ];
    return lines.isEmpty ? '' : '${lines.join('\n')}\n';
  }

  /// Tab when the first line contains one, otherwise whichever of `,` and
  /// `;` occurs more often in it outside quotes (`,` on a tie).
  static String detectDelimiter(String text) {
    var tabs = 0;
    var commas = 0;
    var semicolons = 0;
    var inQuotes = false;
    var started = false;
    for (final char in _stripBom(text).split('')) {
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (!inQuotes) {
        if (char == '\n' || char == '\r') {
          if (started) break;
          continue;
        }
        if (char == '\t') tabs++;
        if (char == ',') commas++;
        if (char == ';') semicolons++;
      }
      if (char.trim().isNotEmpty) started = true;
    }
    if (tabs > 0) return '\t';
    return semicolons > commas ? ';' : ',';
  }

  /// RFC 4180-style splitting into rows of fields. Lenient: accepts `\n`,
  /// `\r\n` and `\r` line ends, whitespace before an opening quote, text
  /// after a closing quote and an unterminated quote (runs to the end).
  /// Rows whose fields are all empty are dropped.
  static List<List<String>> splitRows(String text, String delimiter) {
    final source = _stripBom(text);
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    var inQuotes = false;

    void endField() {
      final value = field.toString();
      row.add(quoted ? value : value.trim());
      field.clear();
      quoted = false;
    }

    void endRow() {
      endField();
      if (row.any((cell) => cell.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if (inQuotes) {
        if (char == '"') {
          if (i + 1 < source.length && source[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(char);
        }
      } else if (char == delimiter) {
        endField();
      } else if (char == '\n' || char == '\r') {
        if (char == '\r' && i + 1 < source.length && source[i + 1] == '\n') {
          i++;
        }
        endRow();
      } else if (char == '"' && !quoted && field.toString().trim().isEmpty) {
        field.clear();
        quoted = true;
        inQuotes = true;
      } else if (!(quoted && char.trim().isEmpty)) {
        // Text after a closing quote is kept, whitespace there is dropped.
        field.write(char);
      }
    }
    if (field.isNotEmpty || quoted || row.isNotEmpty) endRow();
    return rows;
  }

  static String _stripBom(String text) =>
      text.startsWith('﻿') ? text.substring(1) : text;

  static String _cell(List<String> row, int index) =>
      index >= 0 && index < row.length ? row[index] : '';

  static bool _isTrue(String value) => const {
    'true',
    'yes',
    'y',
    '1',
    'x',
    'on',
    '✓',
  }.contains(value.trim().toLowerCase());

  static String _quote(String field, String delimiter) {
    final needsQuotes =
        field.contains(delimiter) ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r') ||
        field != field.trim();
    return needsQuotes ? '"${field.replaceAll('"', '""')}"' : field;
  }

  static const _sourceNames = {
    'source',
    'sourceterm',
    'term',
    'from',
    'original',
    'src',
  };
  static const _targetNames = {
    'target',
    'targetterm',
    'translation',
    'to',
    'tgt',
    'replacement',
  };
  static const _noteNames = {
    'note',
    'notes',
    'comment',
    'comments',
    'description',
  };
  static const _caseNames = {'casesensitive', 'case', 'matchcase', 'cs'};

  /// Column indexes when [row] is a header naming both a source and a target
  /// column, otherwise `null`.
  static _Columns? _headerColumns(List<String> row) {
    int indexOf(Set<String> names) => row.indexWhere(
      (cell) =>
          names.contains(cell.toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '')),
    );
    final source = indexOf(_sourceNames);
    final target = indexOf(_targetNames);
    if (source < 0 || target < 0) return null;
    return _Columns(
      source: source,
      target: target,
      note: indexOf(_noteNames),
      caseFlag: indexOf(_caseNames),
    );
  }
}

class _Columns {
  const new({
    required this.source,
    required this.target,
    required this.note,
    required this.caseFlag,
  });

  final int source;
  final int target;
  final int note;
  final int caseFlag;
}
