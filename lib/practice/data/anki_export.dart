import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// One note of an [AnkiExport]: the [front] and [back] of a card, and its
/// [tags].
final class AnkiNote extends Equatable {
  const new({required this.front, required this.back, this.tags = const []});

  final String front;
  final String back;

  /// Anki tags (spaces become underscores, see [AnkiExport.tag]).
  final List<String> tags;

  @override
  List<Object?> get props => [front, back, tags];
}

/// Phrases as a text file that Anki imports (File > Import): one note per
/// line with the front, the back and the tags, separated by tabs, after
/// the header lines Anki reads (`#separator:tab`, `#html:false` so the
/// text is not read as HTML, `#tags column:3`). Anki maps the first two
/// columns to the fields of its note type in order (Basic, or "Basic (and
/// reversed card)" to practise both ways).
///
/// A field with a tab, a line break or a double quote is quoted (inner
/// quotes doubled), and so is one starting with `#`, so that a first line
/// is never taken for a header. UTF-8 without a byte order mark; lines end
/// with `\n`.
abstract final class AnkiExport {
  /// The file's media type (`.txt`: what Anki's importer and share targets
  /// expect).
  static const mimeType = 'text/plain';

  /// Anki's header lines.
  static const header = '#separator:tab\n#html:false\n#tags column:3\n';

  /// The tag every note gets, the parent of the collection tags
  /// (`Mozhi::Trip_to_Lisbon`).
  static const rootTag = 'Mozhi';

  /// The file's name: `mozhi-anki.txt`, or with [collection]'s name
  /// (letters and digits; others become `-`).
  static String fileName([String? collection]) {
    final slug = (collection ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final short = slug.length > 40 ? slug.substring(0, 40) : slug;
    return short.isEmpty ? 'mozhi-anki.txt' : 'mozhi-anki-$short.txt';
  }

  /// The tag of the collection [name] (below [rootTag]).
  static String collectionTag(String name) => '$rootTag::${tag(name)}';

  /// The tag of a language pair, e.g. `en-pt`.
  static String pairTag(String source, String target) => tag('$source-$target');

  /// [value] as an Anki tag: no spaces (underscores instead), no double
  /// quotes.
  static String tag(String value) =>
      value.trim().replaceAll('"', '').replaceAll(RegExp(r'\s+'), '_');

  /// The file's text: the [header] and one line per note.
  static String encode(Iterable<AnkiNote> notes) {
    final buffer = StringBuffer(header);
    for (final note in notes) {
      final tags = {
        for (final tag in note.tags.map(AnkiExport.tag))
          if (tag.isNotEmpty) tag,
      };
      buffer
        ..writeAll([
          field(note.front),
          field(note.back),
          field(tags.join(' ')),
        ], '\t')
        ..write('\n');
    }
    return buffer.toString();
  }

  /// [encode] in UTF-8.
  static Uint8List bytes(Iterable<AnkiNote> notes) =>
      Uint8List.fromList(utf8.encode(encode(notes)));

  /// [value] as a field.
  static String field(String value) {
    final quote = value.contains(RegExp('[\t\r\n"]')) || value.startsWith('#');
    if (!quote) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}
