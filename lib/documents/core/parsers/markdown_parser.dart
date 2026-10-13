import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/protected_patterns.dart';
import 'package:mozhi/documents/core/source_line.dart';

/// Markdown (CommonMark/GFM subset, line based).
///
/// Kept verbatim: front matter, fenced/indented code blocks, math blocks,
/// HTML comments and `<pre>/<script>/<style>` blocks, thematic breaks,
/// link reference definitions, table delimiter rows and every block
/// marker (`#`, `>`, list bullets, task boxes). Translated: headings,
/// paragraphs (one segment each, soft line breaks kept), list items, quote
/// content, footnote text and table cells. Inline code, links' URLs,
/// images, autolinks, bare URLs, e-mails, HTML tags and entities are
/// protected.
ParsedDocument parseMarkdown(String text) =>
    _MarkdownParser(splitLines(text)).parse();

final _quotePrefix = RegExp(r'^(?:[ \t]*>[ \t]?)+');

/// Container prefix of a line: blockquote markers, then a list marker
/// (with optional task box), heading marker, footnote label, or plain
/// indentation.
final _prefix = RegExp(
  r'^((?:[ \t]*>[ \t]?)*)'
  r'([ \t]*(?:[-+*]|\d{1,9}[.)])(?:[ \t]+\[[ xX]\])?[ \t]+'
  r'|[ \t]*#{1,6}(?:[ \t]+|$)'
  r'|[ \t]*\[\^[^\]]+\]:[ \t]*'
  r'|[ \t]*)',
);
final _listMarker = RegExp(r'^[ \t]*(?:[-+*]|\d{1,9}[.)])');
final _headingMarker = RegExp(r'^[ \t]*#');
final _headingClose = RegExp(r'(?:[ \t]+#+)?[ \t]*$');
final _continuationPrefix = RegExp(r'^(?:[ \t]*>[ \t]?)*[ \t]*');

final _fenceOpen = RegExp(r'^[ \t]*(?:(`{3,})[^`]*|(~{3,}).*)$');
final _mathOpen = RegExp(r'^[ \t]*\$\$');
final _thematicBreak = RegExp(r'^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _setextUnderline = RegExp(r'^[ \t]{0,3}(?:=+|-+)[ \t]*$');
final _linkDefinition = RegExp(r'^[ \t]{0,3}\[[^\]^][^\]]*\]:[ \t]*\S');
final _rawHtmlOpen = RegExp(
  r'^[ \t]*<(pre|script|style|textarea)(?:[\s>]|$)',
  caseSensitive: false,
);
final _tableDelimiter = RegExp(
  r'^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$'
  r'|^[ \t]*\|[ \t]*:?-+:?[ \t]*\|?[ \t]*$',
);
final _frontMatterOpen = RegExp(r'^---[ \t]*$');

/// Block-level HTML tags, which may interrupt a paragraph.
final _htmlBlockTag = RegExp(
  r'^[ \t]{0,3}</?(?:address|article|aside|blockquote|body|center|details|'
  'dialog|dd|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|head|'
  'header|hr|html|li|main|nav|ol|p|section|summary|table|tbody|td|tfoot|th|'
  r'thead|tr|ul)(?:[\s/>]|$)',
  caseSensitive: false,
);
final _frontMatterClose = RegExp(r'^(?:---|\.\.\.)[ \t]*$');

class _MarkdownParser {
  new(this.lines) : lineBreak = dominantLineBreak(lines);

  final List<SourceLine> lines;
  final String lineBreak;
  final DocumentBuilder builder = DocumentBuilder();
  bool _inList = false;

  ParsedDocument parse() {
    var i = 0;
    while (i < lines.length) {
      i = _next(i);
    }
    return builder.build(DocumentFormat.markdown);
  }

  /// Handles the block starting at line [i]; returns the next line index.
  int _next(int i) {
    final line = lines[i];
    final content = line.content;
    if (line.isBlank) return _literal(i, i + 1);

    if (i == 0 && _frontMatterOpen.hasMatch(content)) {
      final end = _find(1, (l) => _frontMatterClose.hasMatch(l.content));
      if (end != -1) return _literal(0, end + 1);
    }

    final unquoted = content.replaceFirst(_quotePrefix, '');
    // An empty quote line (`>`) separates paragraphs like a blank line.
    if (unquoted.trim().isEmpty) return _literal(i, i + 1);

    final fence = _fenceOpen.firstMatch(unquoted);
    if (fence != null) {
      final marker = fence.group(1) ?? fence.group(2)!;
      final close = RegExp(
        '^[ \\t]*${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
      );
      final end = _find(
        i + 1,
        (l) => close.hasMatch(l.content.replaceFirst(_quotePrefix, '')),
      );
      return _literal(i, end == -1 ? lines.length : end + 1);
    }

    if (_mathOpen.hasMatch(unquoted)) {
      final rest = unquoted.trim().substring(2);
      if (rest.trimRight().endsWith(r'$$')) return _literal(i, i + 1);
      final end = _find(i + 1, (l) => l.content.trimRight().endsWith(r'$$'));
      return _literal(i, end == -1 ? lines.length : end + 1);
    }

    if (unquoted.trimLeft().startsWith('<!--')) {
      final end = _find(i, (l) => l.content.contains('-->'));
      return _literal(i, end == -1 ? lines.length : end + 1);
    }

    final rawHtml = _rawHtmlOpen.firstMatch(unquoted);
    if (rawHtml != null) {
      final closing = '</${rawHtml.group(1)!.toLowerCase()}';
      final end = _find(i, (l) => l.content.toLowerCase().contains(closing));
      return _literal(i, end == -1 ? lines.length : end + 1);
    }

    if (!_inList && _indent(content) >= 4 && (i == 0 || lines[i - 1].isBlank)) {
      var end = i + 1;
      while (end < lines.length &&
          (lines[end].isBlank || _indent(lines[end].content) >= 4)) {
        end++;
      }
      // Trailing blank lines are handled as ordinary blank lines.
      while (end > i + 1 && lines[end - 1].isBlank) {
        end--;
      }
      return _literal(i, end);
    }

    if (_thematicBreak.hasMatch(content) ||
        _setextUnderline.hasMatch(content)) {
      _inList = false;
      return _literal(i, i + 1);
    }

    if (_linkDefinition.hasMatch(content)) return _literal(i, i + 1);

    if (content.contains('|') &&
        i + 1 < lines.length &&
        _tableDelimiter.hasMatch(lines[i + 1].content)) {
      _tableRow(lines[i]);
      builder.literal(lines[i + 1].full);
      var end = i + 2;
      while (end < lines.length &&
          !lines[end].isBlank &&
          lines[end].content.contains('|')) {
        _tableRow(lines[end]);
        end++;
      }
      _inList = false;
      return end;
    }

    return _block(i);
  }

  /// Paragraph, heading, list item, quote or footnote starting at [i].
  int _block(int i) {
    final first = lines[i];
    final match = _prefix.firstMatch(first.content)!;
    final quote = match.group(1)!;
    final marker = match.group(2)!;
    final isHeading = _headingMarker.hasMatch(marker);
    final isList = !isHeading && _listMarker.hasMatch(marker);
    final quoteDepth = _depth(quote);
    final prefix = '$quote$marker';
    var text = first.content.substring(prefix.length);

    var suffix = '';
    if (isHeading) {
      final close = _headingClose.firstMatch(text)!;
      suffix = text.substring(close.start);
      text = text.substring(0, close.start);
    }

    builder.literal(prefix);
    final pieces = protect(text, ProtectedPatterns.markdown);
    String? continuation;
    var end = i + 1;
    if (!isHeading) {
      while (end < lines.length &&
          !lines[end].isBlank &&
          !_startsBlock(lines[end].content, quoteDepth)) {
        final next = lines[end].content;
        final prefix = _continuationPrefix.stringMatch(next) ?? '';
        if (next.length == prefix.length) break;
        continuation ??= prefix;
        pieces
          ..add(TextPiece('${lines[end - 1].ending}$prefix', '\n'))
          ..addAll(
            protect(next.substring(prefix.length), ProtectedPatterns.markdown),
          );
        end++;
      }
    }
    continuation ??= isList || quote.isNotEmpty
        ? '$quote${' ' * marker.length}'
        : '';
    builder
      ..addContent(
        pieces,
        lineBreak: first.ending.isEmpty ? lineBreak : first.ending,
        continuation: continuation,
      )
      ..literal('$suffix${lines[end - 1].ending}');

    if (isList) {
      _inList = true;
    } else if (_indent(first.content) == 0 && quote.isEmpty) {
      _inList = false;
    }
    return end;
  }

  /// Whether [content] starts a new block (so it cannot continue a
  /// paragraph in a quote of depth [quoteDepth]).
  bool _startsBlock(String content, int quoteDepth) {
    final match = _prefix.firstMatch(content)!;
    final quote = match.group(1)!;
    final marker = match.group(2)!;
    if (quote.isNotEmpty && _depth(quote) != quoteDepth) return true;
    if (marker.trim().isNotEmpty) return true;
    final rest = content.substring(quote.length);
    final trimmed = rest.trimLeft();
    return _fenceOpen.hasMatch(rest) ||
        _mathOpen.hasMatch(rest) ||
        _thematicBreak.hasMatch(rest) ||
        _setextUnderline.hasMatch(rest) ||
        _linkDefinition.hasMatch(rest) ||
        _rawHtmlOpen.hasMatch(rest) ||
        _htmlBlockTag.hasMatch(rest) ||
        trimmed.startsWith('<!--') ||
        trimmed.startsWith('|');
  }

  void _tableRow(SourceLine line) {
    final content = line.content;
    var start = 0;
    for (final pipe in _pipes(content)) {
      builder
        ..addContent(
          protect(content.substring(start, pipe), ProtectedPatterns.markdown),
        )
        ..literal('|');
      start = pipe + 1;
    }
    builder
      ..addContent(
        protect(content.substring(start), ProtectedPatterns.markdown),
      )
      ..literal(line.ending);
  }

  /// Positions of cell separators: unescaped `|` outside code spans.
  static List<int> _pipes(String content) {
    final pipes = <int>[];
    var inCode = false;
    for (var i = 0; i < content.length; i++) {
      final char = content[i];
      if (char == r'\') {
        i++;
      } else if (char == '`') {
        inCode = !inCode;
      } else if (char == '|' && !inCode) {
        pipes.add(i);
      }
    }
    return pipes;
  }

  int _literal(int start, int end) {
    builder.literal(joinLines(lines, start, end));
    return end;
  }

  int _find(int start, bool Function(SourceLine line) test) {
    for (var i = start; i < lines.length; i++) {
      if (test(lines[i])) return i;
    }
    return -1;
  }

  static int _depth(String quote) => '>'.allMatches(quote).length;

  static int _indent(String content) {
    var width = 0;
    for (var i = 0; i < content.length; i++) {
      final char = content[i];
      if (char == ' ') {
        width++;
      } else if (char == '\t') {
        width += 4 - width % 4;
      } else {
        break;
      }
    }
    return width;
  }
}
