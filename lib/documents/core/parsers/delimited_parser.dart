import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart'
    show NodeList, hasSegment;
import 'package:mozhi/documents/core/parsers/xml_tree.dart'
    show checkDocumentLength;

/// Parses CSV and TSV ([DocumentFormat.csv], [DocumentFormat.tsv]).
///
/// Fields follow RFC 4180: double-quoted fields may hold delimiters, line
/// breaks and doubled quotes (`""`); CRLF, LF and CR line ends, ragged
/// rows and a byte order mark are kept. A CSV file may use `;` or tabs
/// instead of commas (the most frequent one on the first line wins).
///
/// What is translated:
/// * Header: the first row is a header (kept) when the file has at least
///   two rows and every cell of the first row is a short, distinct label
///   (at most 4 words / 40 characters, no sentence punctuation, not a
///   number, date, URL or e-mail address). In a one-column file the label
///   must also look like a column name (`text`, `source_text`, `English`).
/// * Columns: a column is kept when at least 80% of its filled cells are
///   numbers, dates, times, URLs, e-mail addresses, `true`/`false`/`null`
///   or identifiers (`snake_case`, `SKU-123`, UUIDs), or when it repeats a
///   handful of one-word codes (at least 4 filled cells, at most half of
///   them distinct). Other columns are translated cell by cell; cells
///   that are themselves such values, formulas (`=SUM(A1:A3)`) or empty
///   stay as they are.
///
/// Translations are quoted when they need it; placeholders, tags, URLs and
/// e-mail addresses inside cells are protected. A translation that a
/// spreadsheet would run as a formula (it starts with `=`, `+`, `-`, `@`,
/// a tab or a carriage return, after leading spaces) gets a `'` in front,
/// unless its source cell starts that way too (CSV injection).
///
/// Parsing takes linear time: only cells of at most 256 characters are
/// matched against the value patterns above.
///
/// Throws [DocumentParseException] for a quoted field that is never
/// closed.
ParsedDocument parseDelimited(String text, DocumentFormat format) {
  assert(
    format == DocumentFormat.csv || format == DocumentFormat.tsv,
    'not a delimited format: $format',
  );
  checkDocumentLength(text, format.name.toUpperCase());
  return _DelimitedParser(text, format).parse();
}

class _Field {
  new(
    this.start,
    this.end,
    this.value, {
    this.quoted = false,
    this.malformed = false,
  });

  final int start;
  final int end;
  final String value;
  final bool quoted;

  /// Text after the closing quote (`"a"b`): kept as it is.
  final bool malformed;

  /// What the cell holds (worked out once).
  late final _Kind kind = _kind(value);
}

class _Record {
  const new(this.fields, this.end);

  final List<_Field> fields;

  /// Where the record ends, line terminator included.
  final int end;
}

enum _Kind { empty, value, formula, text }

/// Thousands separators of numbers: `,` `.` `'` space and no-break space.
const _thousands = ",.' \u00A0";
final _number = RegExp(
  '^[-+]?(?:[\$€£¥₹]\\s?)?(?:\\d{1,3}(?:[$_thousands]\\d{3})+|\\d+)'
  r'(?:[.,]\d+)?(?:[eE][-+]?\d+)?(?:\s?[%‰])?(?:\s?[$€£¥₹])?$',
);
final _date = RegExp(
  r'^(?:\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?'
  r'(?:Z|[+-]\d{2}:?\d{2})?)?'
  r'|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{4}/\d{1,2}/\d{1,2}'
  r'|\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AaPp][Mm])?)$',
);
final _url = RegExp(r'^(?:(?:https?|ftp)://|www\.|mailto:)\S+$');
final _flag = RegExp(
  r'^(?:true|false|null|none|nil|n/a)$',
  caseSensitive: false,
);
final _code = RegExp(
  r'^(?=.*\d)[A-Za-z0-9]+(?:[-_./:#][A-Za-z0-9]+)+$'
  r'|^(?=.*\d)(?=.*[A-Za-z])[A-Za-z0-9]{2,}$'
  '|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$'
  r'|^[a-z]{2,3}[-_][A-Z]{2}$',
);
final _sentenceEnd = RegExp(r'[.!?:;,…。！？]$');
final _space = RegExp(r'\s');
final _spaces = RegExp(r'\s+');
final _lineBreaks = RegExp('[\t\r\n]+');

/// Longest cell that can be a value (a number, date, URL, e-mail address,
/// flag or code): the value patterns are only ever matched against short
/// text, so that a huge cell can't make parsing slow.
const _maxValueLength = 256;

/// Whether [text] is an e-mail address: no whitespace, a single `@` with
/// something before it, and a dot with something on both sides after it
/// (what `^[^\s@]+@[^\s@]+\.[^\s@]+$` matches, in linear time).
bool _isEmail(String text) {
  final at = text.indexOf('@');
  if (at <= 0 || text.indexOf('@', at + 1) != -1) return false;
  if (_space.hasMatch(text)) return false;
  // A dot after at least one character of the domain, not at its end.
  final dot = text.indexOf('.', at + 2);
  return dot != -1 && dot < text.length - 1;
}

/// Whether a spreadsheet would read [text] as a formula or a DDE call
/// (OWASP's list for CSV injection): it starts with a tab or a carriage
/// return, or with `=`, `+`, `-` or `@` after leading spaces.
bool _startsLikeFormula(String text) {
  if (text.startsWith('\t') || text.startsWith('\r')) return true;
  final trimmed = text.trimLeft();
  return trimmed.isNotEmpty && '=+-@'.contains(trimmed[0]);
}

final _identifierLike = RegExp(
  r'^[a-z][a-z0-9]*(?:[_.-][a-z0-9]+)*$'
  r'|^[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+$'
  r'|^[a-z]+(?:[A-Z][a-z0-9]*)+$|^[a-z]{2,3}(?:[-_][A-Za-z]{2,4})?$',
);

/// Words that name a column of text in a one-column file.
const _columnNames = {
  'text',
  'texts',
  'source',
  'string',
  'strings',
  'value',
  'phrase',
  'phrases',
  'sentence',
  'sentences',
  'term',
  'terms',
  'word',
  'words',
  'message',
  'messages',
  'original',
  'translation',
  'english',
  'name',
  'title',
  'description',
};

_Kind _kind(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return _Kind.empty;
  if (trimmed.startsWith('=')) return _Kind.formula;
  if (!looksLikeNaturalLanguage(trimmed)) return _Kind.value;
  if (trimmed.length > _maxValueLength) return _Kind.text;
  if (_number.hasMatch(trimmed) ||
      _date.hasMatch(trimmed) ||
      _url.hasMatch(trimmed) ||
      _isEmail(trimmed) ||
      _flag.hasMatch(trimmed) ||
      _code.hasMatch(trimmed)) {
    return _Kind.value;
  }
  return _Kind.text;
}

class _DelimitedParser {
  new(this.text, this.format);

  final String text;
  final DocumentFormat format;
  final DocumentBuilder builder = DocumentBuilder();

  ParsedDocument parse() {
    final start = text.startsWith('\uFEFF') ? 1 : 0;
    final delimiter = format == DocumentFormat.tsv
        ? '\t'
        : _guessDelimiter(start);
    final records = _records(start, delimiter);
    final anyQuoted = records.any(
      (record) => record.fields.any((field) => field.quoted),
    );
    final lineBreak = _lineBreak(records);

    final header = _hasHeader(records);
    final columns = records.fold(
      0,
      (count, record) =>
          record.fields.length > count ? record.fields.length : count,
    );
    final translated = [
      for (var column = 0; column < columns; column++)
        _translatedColumn(records, column, skipFirst: header),
    ];
    String columnName(int column) {
      if (header && column < records.first.fields.length) {
        final name = records.first.fields[column].value.trim();
        if (name.isNotEmpty) return name;
      }
      return '${column + 1}';
    }

    final nodes = NodeList()..text(text.substring(0, start));
    var position = start;
    for (var row = 0; row < records.length; row++) {
      final record = records[row];
      for (var column = 0; column < record.fields.length; column++) {
        final field = record.fields[column];
        nodes.text(text.substring(position, field.start));
        position = field.end;
        final raw = text.substring(field.start, field.end);
        if ((header && row == 0) ||
            !translated[column] ||
            field.malformed ||
            field.kind != _Kind.text) {
          nodes.text(raw);
          continue;
        }
        // A source cell that already starts like a formula is the file's
        // own; any other translation must not become one.
        final guard = !_startsLikeFormula(field.value);
        final content = builder.content(
          protect(field.value, LocalisationPatterns.text),
          label: '${columnName(column)}:${row + 1}',
          lineBreak: lineBreak,
        );
        if (!hasSegment(content)) {
          nodes.text(raw);
          continue;
        }
        nodes.addAll([
          EncodedNode(
            raw: raw,
            children: content,
            encode: (value) => _encode(
              value,
              quoted: field.quoted,
              delimiter: delimiter,
              quoteAllowed: format == DocumentFormat.csv || anyQuoted,
              guardFormula: guard,
            ),
          ),
        ]);
      }
      nodes.text(text.substring(position, record.end));
      position = record.end;
    }
    nodes.text(text.substring(position));
    builder.add(nodes.nodes);
    return builder.build(format);
  }

  String _guessDelimiter(int start) {
    var commas = 0;
    var semicolons = 0;
    var tabs = 0;
    var quoted = false;
    for (var i = start; i < text.length; i++) {
      final char = text[i];
      if (char == '"') quoted = !quoted;
      if (quoted) continue;
      if (char == '\n' || char == '\r') break;
      if (char == ',') commas++;
      if (char == ';') semicolons++;
      if (char == '\t') tabs++;
    }
    if (tabs > commas && tabs > semicolons) return '\t';
    if (semicolons > commas) return ';';
    return ',';
  }

  List<_Record> _records(int start, String delimiter) {
    final records = <_Record>[];
    final length = text.length;
    var pos = start;
    bool isEnd(String char) =>
        char == delimiter || char == '\n' || char == '\r';
    while (pos < length) {
      final fields = <_Field>[];
      while (true) {
        final fieldStart = pos;
        if (pos < length && text[pos] == '"') {
          final value = StringBuffer();
          var i = pos + 1;
          while (true) {
            if (i >= length) {
              final line = '\n'
                  .allMatches(text.substring(0, fieldStart))
                  .length;
              throw DocumentParseException(
                '${format.name.toUpperCase()}: the quoted field starting on '
                'line ${line + 1} is not closed',
              );
            }
            final char = text[i];
            if (char == '"') {
              if (i + 1 < length && text[i + 1] == '"') {
                value.write('"');
                i += 2;
                continue;
              }
              i++;
              break;
            }
            value.write(char);
            i++;
          }
          var end = i;
          while (end < length && !isEnd(text[end])) {
            end++;
          }
          fields.add(
            _Field(
              fieldStart,
              end,
              value.toString(),
              quoted: true,
              malformed: end > i,
            ),
          );
          pos = end;
        } else {
          var end = pos;
          while (end < length && !isEnd(text[end])) {
            end++;
          }
          fields.add(_Field(pos, end, text.substring(pos, end)));
          pos = end;
        }
        if (pos < length && text[pos] == delimiter) {
          pos++;
          continue;
        }
        break;
      }
      if (pos < length && text[pos] == '\r') {
        pos += pos + 1 < length && text[pos + 1] == '\n' ? 2 : 1;
      } else if (pos < length && text[pos] == '\n') {
        pos++;
      }
      records.add(_Record(fields, pos));
    }
    return records;
  }

  String _lineBreak(List<_Record> records) {
    for (final record in records) {
      final last = record.fields.last.end;
      if (record.end > last) return text.substring(last, record.end);
    }
    return '\n';
  }

  static bool _isLabel(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return false;
    if (trimmed.split(_spaces).length > 4) return false;
    if (_sentenceEnd.hasMatch(trimmed)) return false;
    if (_number.hasMatch(trimmed) ||
        _date.hasMatch(trimmed) ||
        _url.hasMatch(trimmed) ||
        _isEmail(trimmed)) {
      return false;
    }
    return true;
  }

  bool _hasHeader(List<_Record> records) {
    if (records.length < 2) return false;
    final cells = [
      for (final field in records.first.fields) field.value.trim(),
    ];
    final filled = cells.where((cell) => cell.isNotEmpty).toList();
    if (filled.isEmpty || filled.length < cells.length - 1) return false;
    if (!filled.every(_isLabel)) return false;
    if (filled.map((cell) => cell.toLowerCase()).toSet().length !=
        filled.length) {
      return false;
    }
    if (cells.length == 1) {
      final cell = filled.single;
      return _columnNames.contains(cell.toLowerCase()) ||
          (_identifierLike.hasMatch(cell) && cell.length > 3);
    }
    return true;
  }

  bool _translatedColumn(
    List<_Record> records,
    int column, {
    required bool skipFirst,
  }) {
    final values = <String>[];
    var typed = 0;
    for (var row = skipFirst ? 1 : 0; row < records.length; row++) {
      final fields = records[row].fields;
      if (column >= fields.length) continue;
      final field = fields[column];
      final value = field.value.trim();
      if (value.isEmpty) continue;
      values.add(value);
      if (field.kind != _Kind.text) typed++;
    }
    if (values.isEmpty) return false;
    if (typed >= values.length * 0.8) return false;
    final codes =
        values.length >= 4 &&
        values.every((value) => !value.contains(_space)) &&
        values.toSet().length * 2 <= values.length;
    return !codes;
  }

  static String _encode(
    String translation, {
    required bool quoted,
    required String delimiter,
    required bool quoteAllowed,
    required bool guardFormula,
  }) {
    // OWASP: a leading `'` makes spreadsheets show the cell as text.
    final value = guardFormula && _startsLikeFormula(translation)
        ? "'$translation"
        : translation;
    final special =
        value.contains(delimiter) ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
    if (quoted || (special && quoteAllowed)) {
      return '"${value.replaceAll('"', '""')}"';
    }
    if (!special) return value;
    // Unquoted TSV: no way to escape tabs and line breaks.
    return value.replaceAll(_lineBreaks, ' ');
  }
}
