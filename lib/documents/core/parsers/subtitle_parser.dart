import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/source_line.dart';
import 'package:translation_repository/translation_repository.dart'
    show ProtectedPatterns;

final _timing = RegExp(
  r'^\s*(?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3}\s*-->\s*(?:\d+:)?\d{1,2}:\d{2}'
  r'[,.]\d{1,3}',
);
final _numericId = RegExp(r'^\s*\d+\s*$');

/// SubRip (`.srt`) and WebVTT (`.vtt`) subtitles.
///
/// Only cue text is translated (one segment per cue, its lines joined
/// with `\n`); numbering, identifiers, timestamps, cue settings, the
/// WebVTT header and NOTE/STYLE/REGION blocks stay verbatim. Formatting
/// tags (`<i>`, `<v Speaker>`, `{\an8}`) are protected.
///
/// Cues missing the blank separator line are still recognised: a numeric
/// line right before a timing line is the next cue's number.
ParsedDocument parseSubtitles(String text, DocumentFormat format) {
  assert(format.isSubtitle, 'not a subtitle format: $format');
  final builder = DocumentBuilder();
  final lines = splitLines(text);
  var i = 0;
  var cue = 0;
  while (i < lines.length) {
    if (lines[i].isBlank) {
      builder.literal(lines[i].full);
      i++;
      continue;
    }
    final blockEnd = _blockEnd(lines, i);
    final timings = [
      for (var k = i; k < blockEnd; k++)
        if (_timing.hasMatch(lines[k].content)) k,
    ];
    if (timings.isEmpty) {
      builder.literal(joinLines(lines, i, blockEnd));
      i = blockEnd;
      continue;
    }
    var position = i;
    for (var r = 0; r < timings.length; r++) {
      final timing = timings[r];
      var textEnd = r + 1 < timings.length ? timings[r + 1] : blockEnd;
      if (r + 1 < timings.length &&
          textEnd - 1 > timing &&
          _numericId.hasMatch(lines[textEnd - 1].content)) {
        textEnd--;
      }
      builder.literal(joinLines(lines, position, timing + 1));
      cue++;
      if (textEnd > timing + 1) {
        final pieces = <Piece>[];
        for (var k = timing + 1; k < textEnd; k++) {
          pieces.addAll(protect(lines[k].content, ProtectedPatterns.subtitle));
          if (k < textEnd - 1) pieces.add(TextPiece(lines[k].ending, '\n'));
        }
        final lineBreak = lines[timing].ending.isEmpty
            ? '\n'
            : lines[timing].ending;
        builder
          ..addContent(pieces, lineBreak: lineBreak, label: '$cue')
          ..literal(lines[textEnd - 1].ending);
      }
      position = textEnd;
    }
    i = blockEnd;
  }
  return builder.build(format);
}

int _blockEnd(List<SourceLine> lines, int start) {
  var end = start;
  while (end < lines.length && !lines[end].isBlank) {
    end++;
  }
  return end;
}
