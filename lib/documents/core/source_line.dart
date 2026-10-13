/// One line of a document together with its original terminator.
class SourceLine {
  const SourceLine(this.content, this.ending);

  /// The line without its terminator.
  final String content;

  /// `\n`, `\r\n`, `\r`, or empty for a last line without terminator.
  final String ending;

  /// [content] followed by [ending], i.e. the exact original text.
  String get full => '$content$ending';

  /// Whether the line holds nothing but whitespace.
  bool get isBlank => content.trim().isEmpty;

  @override
  String toString() => 'SourceLine(${full.replaceAll('\n', r'\n')})';
}

/// Splits [text] into lines, keeping every terminator so that joining the
/// [SourceLine.full] values gives [text] back.
///
/// A trailing terminator does not produce an extra empty line.
List<SourceLine> splitLines(String text) {
  final lines = <SourceLine>[];
  var start = 0;
  var i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x0A) {
      lines.add(SourceLine(text.substring(start, i), '\n'));
      start = ++i;
    } else if (unit == 0x0D) {
      final crlf = i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A;
      lines.add(SourceLine(text.substring(start, i), crlf ? '\r\n' : '\r'));
      i += crlf ? 2 : 1;
      start = i;
    } else {
      i++;
    }
  }
  if (start < text.length) lines.add(SourceLine(text.substring(start), ''));
  return lines;
}

/// Joins the original text of `lines[start..end)`.
String joinLines(List<SourceLine> lines, int start, int end) {
  final buffer = StringBuffer();
  for (var i = start; i < end; i++) {
    buffer.write(lines[i].full);
  }
  return buffer.toString();
}

/// The most common line terminator in [lines] (`\n` when there is none).
String dominantLineBreak(List<SourceLine> lines) {
  var crlf = 0;
  var lf = 0;
  var cr = 0;
  for (final line in lines) {
    switch (line.ending) {
      case '\r\n':
        crlf++;
      case '\n':
        lf++;
      case '\r':
        cr++;
    }
  }
  if (crlf > lf && crlf >= cr) return '\r\n';
  if (cr > lf && cr > crlf) return '\r';
  return '\n';
}
