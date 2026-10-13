import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/protected_patterns.dart';
import 'package:mozhi/documents/core/source_line.dart';

/// Plain text: every paragraph (run of non-blank lines) is one segment;
/// blank lines, indentation and line endings are kept. URLs and e-mail
/// addresses are protected.
ParsedDocument parsePlainText(String text) {
  final builder = DocumentBuilder();
  final lines = splitLines(text);
  var i = 0;
  while (i < lines.length) {
    if (lines[i].isBlank) {
      builder.literal(lines[i].full);
      i++;
      continue;
    }
    final start = i;
    while (i < lines.length && !lines[i].isBlank) {
      i++;
    }
    final pieces = <Piece>[];
    for (var k = start; k < i; k++) {
      pieces.addAll(protect(lines[k].content, ProtectedPatterns.plainText));
      if (k < i - 1) pieces.add(TextPiece(lines[k].ending, '\n'));
    }
    final ending = lines[i - 1].ending;
    builder
      ..addContent(
        pieces,
        lineBreak: lines[start].ending.isEmpty ? '\n' : lines[start].ending,
      )
      ..literal(ending);
  }
  return builder.build(DocumentFormat.plainText);
}
