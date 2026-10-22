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
      Uint8List.fromList(utf8.encode('$byteOrderMark${encode(entries)}'));

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
