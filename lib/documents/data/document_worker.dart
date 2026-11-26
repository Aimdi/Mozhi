import 'package:flutter/foundation.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';

/// Parses a text document (`parseDocument`, replaceable in tests).
typedef TextDocumentParser = ParsedDocument Function(
  String text,
  DocumentFormat format, {
  String? targetLanguage,
});

/// Minimum length (in UTF-16 code units) before cooperative chunked parsing
/// splits large plain-text documents on the web.
const int webTextChunkThreshold = 128 * 1024;

/// Target size of each cooperative plain-text chunk on the web.
const int webTextChunkSize = 64 * 1024;

/// Parses [text] with [parser] in a background isolate (on the web, where
/// there are none, cooperatively on the UI thread with macrotask yields).
/// Errors arrive as they were thrown.
Future<ParsedDocument> parseTextInBackground(
  TextDocumentParser parser,
  String text,
  DocumentFormat format, {
  String? targetLanguage,
  bool expandPlurals = false,
}) => kIsWeb
    ? parseTextCooperatively(
        parser,
        text,
        format,
        targetLanguage: targetLanguage,
        expandPlurals: expandPlurals,
      )
    : compute(_parseText, (
        parser,
        text,
        format,
        targetLanguage,
        expandPlurals,
      ));

/// Cooperatively parses [text] on the current isolate, yielding to the event
/// loop before parsing and between safe structural chunks for large text,
/// Markdown (`.md`), subtitle (`.srt`, `.vtt`) and `.properties` files
/// (> [chunkThreshold]) without changing the parse result.
Future<ParsedDocument> parseTextCooperatively(
  TextDocumentParser parser,
  String text,
  DocumentFormat format, {
  String? targetLanguage,
  bool expandPlurals = false,
  int chunkThreshold = webTextChunkThreshold,
  int chunkSize = webTextChunkSize,
  Future<void> Function()? yieldTurn,
}) async {
  final pause = yieldTurn ?? _yield;
  await pause();
  if (!identical(parser, parseDocument) ||
      text.length <= chunkThreshold ||
      !_supportsCooperativeChunking(format)) {
    return _invokeParser(
      parser,
      text,
      format,
      targetLanguage: targetLanguage,
      expandPlurals: expandPlurals,
    );
  }
  final chunks = switch (format) {
    DocumentFormat.plainText ||
    DocumentFormat.srt ||
    DocumentFormat.vtt => _splitPlainTextChunks(text, chunkSize),
    DocumentFormat.markdown => _splitMarkdownChunks(text, chunkSize),
    DocumentFormat.properties => _splitPropertiesChunks(text, chunkSize),
    _ => [text],
  };
  if (chunks.length <= 1) {
    return _invokeParser(
      parser,
      text,
      format,
      targetLanguage: targetLanguage,
      expandPlurals: expandPlurals,
    );
  }
  final parsed = <ParsedDocument>[];
  final cueOffsets = format.isSubtitle ? <int>[] : null;
  var totalCues = 0;
  for (var i = 0; i < chunks.length; i++) {
    if (i > 0) await pause();
    final chunk = chunks[i];
    if (cueOffsets != null) {
      cueOffsets.add(totalCues);
      totalCues += _countSubtitleCues(chunk);
    }
    parsed.add(
      _invokeParser(
        parser,
        chunk,
        format,
        targetLanguage: targetLanguage,
        expandPlurals: expandPlurals,
      ),
    );
  }
  return _mergeParsedDocuments(format, parsed, cueOffsets: cueOffsets);
}

bool _supportsCooperativeChunking(DocumentFormat format) =>
    format == DocumentFormat.plainText ||
    format == DocumentFormat.markdown ||
    format == DocumentFormat.srt ||
    format == DocumentFormat.vtt ||
    format == DocumentFormat.properties;

final _mdQuotePrefix = RegExp(r'^(?:[ \t]*>[ \t]?)+');
final _mdFenceOpen = RegExp(r'^[ \t]*(?:(`{3,})[^`]*|(~{3,}).*)$');
final _mdMathOpen = RegExp(r'^[ \t]*\$\$');
final _mdRawHtmlOpen = RegExp(
  r'^[ \t]*<(pre|script|style|textarea)(?:[\s>]|$)',
  caseSensitive: false,
);
final _mdFrontMatterOpen = RegExp(r'^---[ \t]*$');
final _mdFrontMatterClose = RegExp(r'^(?:---|\.\.\.)[ \t]*$');
final _mdThematicBreak = RegExp(r'^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _mdSetextUnderline = RegExp(r'^[ \t]{0,3}(?:=+|-+)[ \t]*$');
final _mdListMarker = RegExp(
  r'^[ \t]*(?:[-+*]|\d{1,9}[.)])(?:[ \t]+\[[ xX]\])?[ \t]+',
);
final _mdHeadingMarker = RegExp(r'^[ \t]*#{1,6}(?:[ \t]+|$)');

int _mdIndentWidth(String content) {
  var width = 0;
  for (var i = 0; i < content.length; i++) {
    final c = content.codeUnitAt(i);
    if (c == 0x20) {
      width++;
    } else if (c == 0x09) {
      width += 4 - width % 4;
    } else {
      break;
    }
  }
  return width;
}

/// Splits a Markdown document into chunks of about [targetSize] characters,
/// cutting only at top-level blank-line boundaries where `parseMarkdown`
/// produces the exact same AST and segments as parsing the whole document.
List<String> _splitMarkdownChunks(String text, int targetSize) {
  final hasCrlf = text.contains('\r\n');
  final lineStarts = <int>[];
  final lineEnds = <int>[];
  final contents = <String>[];
  final isBlanks = <bool>[];

  var pos = 0;
  final length = text.length;
  while (pos < length) {
    final nl = text.indexOf('\n', pos);
    final lineEnd = nl < 0 ? length : nl + 1;
    final contentEnd = nl < 0
        ? length
        : (nl > pos && text.codeUnitAt(nl - 1) == 0x0D ? nl - 1 : nl);
    final content = text.substring(pos, contentEnd);
    lineStarts.add(pos);
    lineEnds.add(lineEnd);
    contents.add(content);
    isBlanks.add(content.trim().isEmpty);
    pos = lineEnd;
  }
  if (contents.isEmpty) return [text];

  final chunks = <String>[];
  var chunkStart = 0;
  var inList = false;
  var i = 0;

  while (i < contents.length) {
    final content = contents[i];
    if (isBlanks[i]) {
      final cutPos = lineEnds[i];
      i++;
      if (i < contents.length &&
          !isBlanks[i] &&
          cutPos - chunkStart >= targetSize &&
          (!hasCrlf || text.indexOf('\n', cutPos) != -1)) {
        final next = contents[i];
        final nextIndent = _mdIndentWidth(next);
        final nextTrimmed = next.trimLeft();
        final safeNext =
            nextIndent == 0 &&
            !nextTrimmed.startsWith('>') &&
            !_mdFrontMatterOpen.hasMatch(next) &&
            (!inList ||
                _mdListMarker.hasMatch(next) ||
                _mdHeadingMarker.hasMatch(next));
        if (safeNext) {
          chunks.add(text.substring(chunkStart, cutPos));
          chunkStart = cutPos;
          inList = false;
        }
      }
      continue;
    }

    if (i == 0 && _mdFrontMatterOpen.hasMatch(content)) {
      var end = -1;
      for (var j = 1; j < contents.length; j++) {
        if (_mdFrontMatterClose.hasMatch(contents[j])) {
          end = j;
          break;
        }
      }
      if (end != -1) {
        i = end + 1;
        continue;
      }
    }

    final unquoted = content.replaceFirst(_mdQuotePrefix, '');
    if (unquoted.trim().isEmpty) {
      i++;
      continue;
    }

    final fence = _mdFenceOpen.firstMatch(unquoted);
    if (fence != null) {
      final marker = fence.group(1) ?? fence.group(2)!;
      final close = RegExp(
        '^[ \\t]*${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
      );
      var end = contents.length - 1;
      for (var j = i + 1; j < contents.length; j++) {
        if (close.hasMatch(contents[j].replaceFirst(_mdQuotePrefix, ''))) {
          end = j;
          break;
        }
      }
      i = end + 1;
      continue;
    }

    if (_mdMathOpen.hasMatch(unquoted)) {
      final rest = unquoted.trim().substring(2);
      if (rest.trimRight().endsWith(r'$$')) {
        i++;
        continue;
      }
      var end = contents.length - 1;
      for (var j = i + 1; j < contents.length; j++) {
        if (contents[j].trimRight().endsWith(r'$$')) {
          end = j;
          break;
        }
      }
      i = end + 1;
      continue;
    }

    if (unquoted.trimLeft().startsWith('<!--')) {
      var end = contents.length - 1;
      for (var j = i; j < contents.length; j++) {
        if (contents[j].contains('-->')) {
          end = j;
          break;
        }
      }
      i = end + 1;
      continue;
    }

    final rawHtml = _mdRawHtmlOpen.firstMatch(unquoted);
    if (rawHtml != null) {
      final closing = '</${rawHtml.group(1)!.toLowerCase()}';
      var end = contents.length - 1;
      for (var j = i; j < contents.length; j++) {
        if (contents[j].toLowerCase().contains(closing)) {
          end = j;
          break;
        }
      }
      i = end + 1;
      continue;
    }

    if (!inList &&
        _mdIndentWidth(content) >= 4 &&
        (i == 0 || isBlanks[i - 1])) {
      var end = i + 1;
      while (end < contents.length &&
          (isBlanks[end] || _mdIndentWidth(contents[end]) >= 4)) {
        end++;
      }
      while (end > i + 1 && isBlanks[end - 1]) {
        end--;
      }
      i = end;
      continue;
    }

    if (_mdThematicBreak.hasMatch(content) ||
        _mdSetextUnderline.hasMatch(content)) {
      inList = false;
      i++;
      continue;
    }

    if (_mdListMarker.hasMatch(unquoted)) {
      inList = true;
    } else if (_mdIndentWidth(content) == 0 &&
        !_mdQuotePrefix.hasMatch(content)) {
      inList = false;
    }
    i++;
  }

  if (chunkStart < length) {
    chunks.add(text.substring(chunkStart));
  }
  return chunks;
}

final _subtitleTimingLine = RegExp(
  r'^\s*(?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3}\s*-->\s*(?:\d+:)?\d{1,2}:\d{2}'
  r'[,.]\d{1,3}',
  multiLine: true,
);

int _countSubtitleCues(String chunk) =>
    _subtitleTimingLine.allMatches(chunk).length;

/// Splits a Java `.properties` file into chunks of about [targetSize]
/// characters, cutting only after lines that do not end with an unescaped
/// backslash continuation (`\`) and never right before a mid-file BOM.
List<String> _splitPropertiesChunks(String text, int targetSize) {
  final chunks = <String>[];
  final length = text.length;
  var chunkStart = 0;
  var pos = 0;

  while (pos < length) {
    final nl = text.indexOf('\n', pos);
    final lineEnd = nl < 0 ? length : nl + 1;
    final contentEnd = nl < 0
        ? length
        : (nl > pos && text.codeUnitAt(nl - 1) == 0x0D ? nl - 1 : nl);
    var backslashes = 0;
    for (var i = contentEnd - 1; i >= pos; i--) {
      if (text.codeUnitAt(i) == 0x5C) {
        backslashes++;
      } else {
        break;
      }
    }
    pos = lineEnd;
    if (backslashes.isEven &&
        pos < length &&
        pos - chunkStart >= targetSize &&
        text.codeUnitAt(pos) != 0xFEFF) {
      chunks.add(text.substring(chunkStart, pos));
      chunkStart = pos;
    }
  }
  if (chunkStart < length) {
    chunks.add(text.substring(chunkStart));
  }
  return chunks;
}

Future<void> _yield() => Future<void>.delayed(Duration.zero);

/// Splits [text] into chunks of about [targetSize] characters, cutting only
/// right after a blank line so no paragraph is ever split across chunks.
List<String> _splitPlainTextChunks(String text, int targetSize) {
  final chunks = <String>[];
  final length = text.length;
  var chunkStart = 0;
  var pos = 0;

  while (pos < length) {
    final nl = text.indexOf('\n', pos);
    final lineEnd = nl < 0 ? length : nl + 1;
    final contentEnd = nl < 0
        ? length
        : (nl > pos && text.codeUnitAt(nl - 1) == 0x0D ? nl - 1 : nl);
    var isBlank = true;
    for (var i = pos; i < contentEnd; i++) {
      final c = text.codeUnitAt(i);
      if (c != 0x20 && c != 0x09 && c != 0x0D) {
        isBlank = false;
        break;
      }
    }
    pos = lineEnd;
    if (isBlank && pos < length && pos - chunkStart >= targetSize) {
      chunks.add(text.substring(chunkStart, pos));
      chunkStart = pos;
    }
  }
  if (chunkStart < length) {
    chunks.add(text.substring(chunkStart));
  }
  return chunks;
}

/// Combines chunked [ParsedDocument]s into a single [ParsedDocument] with
/// continuous segment indices and merged adjacent [TextNode]s.
ParsedDocument _mergeParsedDocuments(
  DocumentFormat format,
  List<ParsedDocument> parts, {
  List<int>? cueOffsets,
}) {
  final nodes = <DocNode>[];
  final segments = <Segment>[];
  final segmentNodes = <SegmentNode>[];

  DocNode remap(DocNode node, int offset) => switch (node) {
    TextNode() => node,
    SegmentNode() => SegmentNode(
      segment: node.segment + offset,
      sourceParts: node.sourceParts,
      tokens: [
        for (final token in node.tokens)
          [for (final child in token) remap(child, offset)],
      ],
      glueBefore: node.glueBefore,
      glueAfter: node.glueAfter,
      lineBreak: node.lineBreak,
      continuation: node.continuation,
      escape: node.escape,
    ),
    EncodedNode() => EncodedNode(
      raw: node.raw,
      children: [for (final child in node.children) remap(child, offset)],
      encode: node.encode,
    ),
  };

  void addNode(DocNode node) {
    if (node is TextNode && nodes.isNotEmpty && nodes.last is TextNode) {
      nodes[nodes.length - 1] = TextNode(
        '${(nodes.last as TextNode).text}${node.text}',
      );
    } else {
      nodes.add(node);
    }
  }

  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final offset = segments.length;
    final cueOffset = cueOffsets == null ? 0 : cueOffsets[i];
    if (cueOffset == 0) {
      segments.addAll(part.segments);
    } else {
      for (final segment in part.segments) {
        final number = segment.label == null
            ? null
            : int.tryParse(segment.label!);
        segments.add(
          number == null
              ? segment
              : Segment(
                  segment.text,
                  label: '${number + cueOffset}',
                  contextHint: segment.contextHint,
                ),
        );
      }
    }
    for (final node in part.nodes) {
      final remapped = offset == 0 ? node : remap(node, offset);
      addNode(remapped);
      _collectSegmentNodes(remapped, segmentNodes);
    }
  }
  return ParsedDocument(
    format: format,
    nodes: nodes,
    segments: segments,
    segmentNodes: segmentNodes,
  );
}

void _collectSegmentNodes(DocNode node, List<SegmentNode> out) {
  switch (node) {
    case TextNode():
      break;
    case SegmentNode():
      out.add(node);
      for (final token in node.tokens) {
        for (final child in token) {
          _collectSegmentNodes(child, out);
        }
      }
    case EncodedNode(:final children):
      for (final child in children) {
        _collectSegmentNodes(child, out);
      }
  }
}

/// Parses an office document or e-book in a background isolate (on the
/// web, part by part on the same thread, yielding between parts). Errors
/// ([PackageParseException]) arrive as they were thrown.
Future<PackagedDocument> parsePackageInBackground(
  Uint8List bytes,
  DocumentFormat format, {
  String? targetLanguage,
}) => kIsWeb
    // No isolates: parse part by part, letting the page paint in between.
    ? OfficePackage.parseAsync(bytes, format, targetLanguage: targetLanguage)
    : compute(_parsePackage, (bytes, format, targetLanguage));

/// Renders [document] with [translations] in a background isolate (on the
/// web, part by part on the same thread).
Future<Uint8List> renderPackageInBackground(
  PackagedDocument document,
  List<String?> translations,
) => kIsWeb && document is OfficePackage
    ? document.renderAsync(translations)
    : compute(_render, (document, translations));

ParsedDocument _invokeParser(
  TextDocumentParser parser,
  String text,
  DocumentFormat format, {
  required bool expandPlurals,
  String? targetLanguage,
}) => expandPlurals && identical(parser, parseDocument)
    ? parseDocument(
        text,
        format,
        targetLanguage: targetLanguage,
        expandPlurals: true,
      )
    : parser(text, format, targetLanguage: targetLanguage);

ParsedDocument _parseText(
  (TextDocumentParser parser, String text, DocumentFormat format, String?, bool)
  job,
) => _invokeParser(
  job.$1,
  job.$2,
  job.$3,
  targetLanguage: job.$4,
  expandPlurals: job.$5,
);

PackagedDocument _parsePackage(
  (Uint8List bytes, DocumentFormat format, String? target) job,
) => parsePackagedDocument(job.$1, job.$2, targetLanguage: job.$3);

Uint8List _render(
  (PackagedDocument document, List<String?> translations) job,
) => job.$1.render(job.$2);
