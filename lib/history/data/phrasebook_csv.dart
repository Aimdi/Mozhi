import 'dart:convert';
import 'dart:typed_data';

import 'package:mozhi/history/cubit/history_filters.dart';
import 'package:mozhi/history/models/history_entry.dart';

/// Favourites as a phrasebook file that Anki and spreadsheets import: one
/// row per entry with the front (the text, or a look-up's word), the back
/// (the translation, or the look-up's summary), the source and target
/// languages and the date (`yyyy-MM-dd`, local).
///
/// RFC 4180 CSV: comma-separated, CRLF line endings, fields with a comma,
/// a double quote, a line break or leading/trailing spaces quoted (inner
/// quotes doubled). UTF-8 with a byte order mark, so that spreadsheets
/// read the text as UTF-8.
///
/// It starts with Anki's header lines (`#separator:Comma`, `#html:false`;
/// Anki skips the byte order mark): Anki then maps the columns in order
/// (front, back) in any language of its note types, and does not read the
/// text as HTML. A field starting with `#` is quoted, so that a first row
/// is never taken for a header line.
abstract final class PhrasebookCsv {
  /// The file's name.
  static const fileName = 'mozhi-favorites.csv';

  /// The file's media type.
  static const mimeType = 'text/csv';

  /// The UTF-8 byte order mark.
  static const byteOrderMark = '﻿';

  /// Anki's header lines.
  static const header = '#separator:Comma\r\n#html:false\r\n';

  /// The rows of [entries] (with the [header], without the byte order
  /// mark).
  static String encode(Iterable<HistoryEntry> entries) {
    final buffer = StringBuffer(header);
    for (final entry in entries) {
      final pair = HistoryPair.of(entry);
      buffer
        ..writeAll([
          field(entry.text),
          field(entry.translation),
          field(pair.source.name),
          field(pair.target.name),
          field(date(entry.createdAt)),
        ], ',')
        ..write('\r\n');
    }
    return buffer.toString();
  }

  /// The file: [encode] in UTF-8 after a byte order mark.
  static Uint8List bytes(Iterable<HistoryEntry> entries) =>
      textBytes(encode(entries));

  /// [rows] with the [header] (as [encode] writes them: every value an
  /// RFC 4180 [field], CRLF line endings), without the byte order mark.
  static String encodeRows(Iterable<List<String>> rows) {
    final buffer = StringBuffer(header);
    for (final row in rows) {
      buffer
        ..writeAll([for (final value in row) field(value)], ',')
        ..write('\r\n');
    }
    return buffer.toString();
  }

  /// [csv] as a file: UTF-8 after a byte order mark.
  static Uint8List textBytes(String csv) =>
      Uint8List.fromList(utf8.encode('$byteOrderMark$csv'));

  /// The most rows [parse] reads.
  static const maxRows = 20000;

  /// Reads CSV [text]: this app's files, Anki's text exports and
  /// spreadsheets' CSV.
  ///
  /// A byte order mark is skipped, and so are Anki's header lines at the
  /// start (lines starting with `#`, e.g. `#separator:Tab`), whose
  /// `#separator:` names the separator (`Comma`, `Semicolon`, `Tab`,
  /// `Pipe`, `Space`, `Colon` or the character itself). Without one, the
  /// separator is the one of tab, semicolon and comma that occurs most
  /// often outside quotes in the first line. Fields may be quoted (`"`,
  /// inner quotes doubled) and span lines; lines end with CRLF, LF or CR.
  /// Empty lines are skipped, and at most [maxRows] rows are read.
  static CsvTable parse(String text) {
    var source = text.startsWith(byteOrderMark) ? text.substring(1) : text;
    String? separator;
    // Anki's header lines.
    while (source.startsWith('#')) {
      final end = source.indexOf(RegExp('\r\n|\n|\r'));
      final line = end == -1 ? source : source.substring(0, end);
      final match = RegExp(
        r'^#separator:(.*)$',
        caseSensitive: false,
      ).firstMatch(line.trim());
      if (match != null) separator = _separatorNamed(match.group(1)!.trim());
      if (end == -1) {
        source = '';
        break;
      }
      final skip = source.startsWith('\r\n', end) ? 2 : 1;
      source = source.substring(end + skip);
    }
    final sep = separator ?? _sniffSeparator(source);
    final rows = <List<String>>[];
    var row = <String>[];
    final value = StringBuffer();
    var quoted = false;
    var fieldStarted = false;
    void endField() {
      row.add(value.toString());
      value.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < source.length && rows.length < maxRows; i++) {
      final char = source[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < source.length && source[i + 1] == '"') {
            value.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          value.write(char);
        }
        continue;
      }
      if (char == '"' && !fieldStarted && value.isEmpty) {
        quoted = true;
        fieldStarted = true;
      } else if (char == sep) {
        endField();
      } else if (char == '\r' || char == '\n') {
        if (char == '\r' && i + 1 < source.length && source[i + 1] == '\n') {
          i++;
        }
        endRow();
      } else {
        value.write(char);
        fieldStarted = true;
      }
    }
    if ((value.isNotEmpty || row.isNotEmpty || fieldStarted) &&
        rows.length < maxRows) {
      endRow();
    }
    return CsvTable(rows: List.unmodifiable(rows), separator: sep);
  }

  static String? _separatorNamed(String name) => switch (name.toLowerCase()) {
    'comma' => ',',
    'semicolon' => ';',
    'tab' => '\t',
    'pipe' => '|',
    'space' => ' ',
    'colon' => ':',
    _ when name.length == 1 => name,
    _ => null,
  };

  /// The separator of [text]'s first line: the most frequent of tab,
  /// semicolon and comma outside quotes (comma when none occurs).
  static String _sniffSeparator(String text) {
    final counts = {'\t': 0, ';': 0, ',': 0};
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '"') {
        quoted = !quoted;
      } else if (!quoted && (char == '\n' || char == '\r')) {
        break;
      } else if (!quoted && counts.containsKey(char)) {
        counts[char] = counts[char]! + 1;
      }
    }
    var best = ',';
    for (final MapEntry(:key, :value) in counts.entries) {
      if (value > counts[best]!) best = key;
    }
    return best;
  }

  /// [value] as an RFC 4180 field.
  static String field(String value) {
    final quote =
        value.contains(RegExp('[",\r\n]')) ||
        value.startsWith('#') ||
        value != value.trim();
    if (!quote) return value;
    return '"${value.replaceAll('"', '""')}"';
  }

  /// [time]'s local date as `yyyy-MM-dd`.
  static String date(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-'
        '${two(local.month)}-${two(local.day)}';
  }
}

/// The rows of a CSV file read by [PhrasebookCsv.parse].
class CsvTable {
  const new({required this.rows, required this.separator});

  /// The rows, each a list of fields (rows may differ in length).
  final List<List<String>> rows;

  /// The separator the file used.
  final String separator;

  /// The number of columns: the longest row's length.
  int get columns =>
      rows.fold<int>(0, (most, row) => row.length > most ? row.length : most);

  /// Field [column] of [row], or an empty string when the row is shorter.
  static String cell(List<String> row, int column) =>
      column < row.length ? row[column] : '';
}
