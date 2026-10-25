/// Shared pieces of the markup parsers (HTML, XLIFF, Android strings):
/// inline content with codes, character references, escaping and the
/// repair of inline tags an engine moved around.
library;

import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/locale_rules.dart'
    show LocalisationPatterns;
import 'package:mozhi/documents/core/parsers/markup_lexer.dart';
import 'package:mozhi/web_translate/core/html_entities.dart';

/// Part of a run of inline content.
sealed class Inline {
  const new();
}

/// Text: [source] as written, [text] as the translator sees it (decoded
/// references, collapsed whitespace).
final class InlineText extends Inline {
  const new(this.source, [String? text]) : text = text ?? source;

  final String source;
  final String text;
}

/// How an [InlineCode] relates to its neighbours.
enum CodeRole {
  /// Opens an inline element whose content is translated with the rest
  /// (`<b>`, `<g id="1">`); [InlineCode.pair] links it to its close.
  open,

  /// Closes the element opened by the code with the same pair number.
  close,

  /// Stands alone (`<br>`, `<x/>`, a comment, a whole `<code>` element,
  /// a reference such as `&nbsp;`).
  standalone,
}

/// Markup inside a run that is not translated: becomes a placeholder.
final class InlineCode extends Inline {
  const new(
    this.nodes, {
    this.role = CodeRole.standalone,
    this.pair = -1,
    this.movable = false,
  });

  new text(
    String raw, {
    CodeRole role = CodeRole.standalone,
    int pair = -1,
    bool movable = false,
  }) : this([TextNode(raw)], role: role, pair: pair, movable: movable);

  /// What the code renders (may contain segments, e.g. a translated `alt`).
  final List<DocNode> nodes;
  final CodeRole role;
  final int pair;

  /// Whether a standalone code at the start or end of the run may stay out
  /// of the segment (line breaks, comments).
  final bool movable;
}

/// The original text that [nodes] render without translations.
String identityText(List<DocNode> nodes) {
  final buffer = StringBuffer();
  void write(List<DocNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case TextNode(:final text):
          buffer.write(text);
        case EncodedNode(:final raw):
          buffer.write(raw);
        case SegmentNode(:final sourceParts, :final tokens):
          for (var i = 0; i < sourceParts.length; i++) {
            buffer.write(sourceParts[i]);
            if (i < tokens.length) write(tokens[i]);
          }
      }
    }
  }

  write(nodes);
  return buffer.toString();
}

/// Whether [nodes] contain a segment.
bool hasSegment(List<DocNode> nodes) => nodes.any(
  (node) => switch (node) {
    SegmentNode() => true,
    EncodedNode(:final children) => hasSegment(children),
    TextNode() => false,
  },
);

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

/// Escapes text content for XML and HTML (`&`, `<`, `>`).
String escapeMarkupText(String text) {
  if (!text.contains(_markupSpecial)) return text;
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

final _markupSpecial = RegExp('[&<>]');

/// Escapes an attribute value written between [quote]s (`"`, `'`, or
/// empty for an unquoted value, which is then quoted with `"` by the
/// caller). Line breaks become spaces.
String escapeMarkupAttribute(String text, String quote) {
  final value = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll(_attributeBreaks, ' ');
  return quote == "'"
      ? value.replaceAll("'", '&#39;')
      : value.replaceAll('"', '&quot;');
}

final _attributeBreaks = RegExp(r'[\r\n\t]+');

/// Writes [text] inside a CDATA section (splitting any `]]>`).
String escapeCdata(String text) => text.replaceAll(']]>', ']]]]><![CDATA[>');

// ---------------------------------------------------------------------------
// Character references
// ---------------------------------------------------------------------------

/// A character reference (`&amp;`, `&#233;`, `&#xE9;`, legacy `&copy`).
final characterReference = RegExp(
  '&(?:#[0-9]{1,8};?|#[xX][0-9a-fA-F]{1,8};?|[A-Za-z][A-Za-z0-9]{0,31};?)',
);

final _invisible = RegExp(r'[\s\p{C}]', unicode: true);

const _xmlEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
};

/// Decodes one character reference [raw] (`&amp;`, `&#233;`); null when it
/// is not one (in XML only the five predefined names exist).
String? decodeReference(String raw, {required bool html}) {
  if (raw.length < 3 || raw[0] != '&') return null;
  if (raw[1] == '#') {
    final hex = raw[2] == 'x' || raw[2] == 'X';
    final digits = raw.substring(hex ? 3 : 2).replaceFirst(';', '');
    if (digits.isEmpty) return null;
    if (!html && !raw.endsWith(';')) return null;
    final value = int.tryParse(digits, radix: hex ? 16 : 10);
    if (value == null ||
        value == 0 ||
        value > 0x10FFFF ||
        (value >= 0xD800 && value <= 0xDFFF)) {
      return null;
    }
    return String.fromCharCode(value);
  }
  if (!raw.endsWith(';')) {
    if (!html) return null;
    // A legacy name without semicolon (`&copy`): known only as a whole.
    final decoded = decodeHtmlEntities(raw);
    return decoded == raw ? null : decoded;
  }
  final name = raw.substring(1, raw.length - 1);
  return html ? htmlNamedEntities[name] : _xmlEntities[name];
}

/// Decodes the character references of an attribute value.
String decodeAttributeValue(String raw, {required bool html}) {
  if (!raw.contains('&')) return raw;
  return raw.replaceAllMapped(
    characterReference,
    (match) => decodeReference(match.group(0)!, html: html) ?? match.group(0)!,
  );
}

/// Splits raw character data into [Inline]s.
///
/// References that decode to visible characters (`&amp;`, `&eacute;`)
/// become text the translator reads decoded (and the escape function
/// writes back); the others (`&nbsp;`, `&#8203;`, unknown names) stay as
/// codes. With [collapse] (HTML), every run of HTML whitespace other than
/// a single space reads as one space.
List<Inline> textInlines(
  String source,
  int start,
  int end, {
  required bool html,
  bool collapse = false,
}) {
  final items = <Inline>[];
  final plain = StringBuffer();
  void flush() {
    if (plain.isEmpty) return;
    items.add(InlineText(plain.toString()));
    plain.clear();
  }

  var i = start;
  while (i < end) {
    final c = source.codeUnitAt(i);
    if (c == 0x26) {
      final match = characterReference.matchAsPrefix(source, i);
      if (match != null && match.end <= end) {
        final raw = match.group(0)!;
        final decoded = decodeReference(raw, html: html);
        flush();
        if (decoded != null && !decoded.contains(_invisible)) {
          items.add(InlineText(raw, decoded));
        } else if (decoded != null || raw.endsWith(';')) {
          items.add(InlineCode.text(raw));
        } else {
          // `AT&T`: not a reference, shown as written.
          items.add(InlineText(raw));
        }
        i = match.end;
        continue;
      }
    }
    if (collapse && _isHtmlSpace(c)) {
      var j = i;
      while (j < end && _isHtmlSpace(source.codeUnitAt(j))) {
        j++;
      }
      final run = source.substring(i, j);
      if (run == ' ') {
        plain.write(' ');
      } else {
        flush();
        items.add(InlineText(run, ' '));
      }
      i = j;
      continue;
    }
    plain.writeCharCode(c);
    i++;
  }
  flush();
  return items;
}

bool _isHtmlSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;

/// Splits [inlines] further where [pattern] (placeholders such as `%1$s`,
/// URLs, escaped markup) matches the decoded text; the matches become
/// standalone codes holding their source text.
///
/// A match is widened to whole references and collapsed whitespace runs,
/// which are never split.
List<Inline> protectInlines(List<Inline> inlines, RegExp? pattern) {
  if (pattern == null) return inlines;
  final result = <Inline>[];
  var i = 0;
  while (i < inlines.length) {
    if (inlines[i] is! InlineText) {
      result.add(inlines[i]);
      i++;
      continue;
    }
    final run = <InlineText>[];
    while (i < inlines.length && inlines[i] is InlineText) {
      run.add(inlines[i] as InlineText);
      i++;
    }
    result.addAll(_protectRun(run, pattern));
  }
  return result;
}

List<Inline> _protectRun(List<InlineText> run, RegExp pattern) {
  // starts[k]: offset of run[k] in the decoded text.
  final starts = <int>[];
  final decoded = StringBuffer();
  for (final item in run) {
    starts.add(decoded.length);
    decoded.write(item.text);
  }
  final text = decoded.toString();
  final total = text.length;

  int itemAt(int offset) {
    var low = 0;
    var high = run.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  bool atomic(InlineText item) => item.source != item.text;

  // Moves [offset] to the start (or end) of an atomic item it falls into.
  int snap(int offset, {required bool down}) {
    if (offset <= 0 || offset >= total) return offset;
    final k = itemAt(offset);
    if (!atomic(run[k]) || starts[k] == offset) return offset;
    return down ? starts[k] : starts[k] + run[k].text.length;
  }

  // The items between decoded offsets [from] and [to] (snapped).
  List<InlineText> slice(int from, int to) {
    final parts = <InlineText>[];
    if (to <= from) return parts;
    for (var k = itemAt(from); k < run.length && starts[k] < to; k++) {
      final item = run[k];
      final itemStart = starts[k];
      final itemEnd = itemStart + item.text.length;
      if (itemEnd <= from) continue;
      if (atomic(item)) {
        parts.add(item);
      } else {
        final a = (from > itemStart ? from : itemStart) - itemStart;
        final b = (to < itemEnd ? to : itemEnd) - itemStart;
        parts.add(InlineText(item.source.substring(a, b)));
      }
    }
    return parts;
  }

  final result = <Inline>[];
  var position = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.end == match.start) continue;
    final from = snap(match.start, down: true);
    final to = snap(match.end, down: false);
    if (from < position) continue;
    result.addAll(slice(position, from));
    final code = slice(from, to).map((item) => item.source).join();
    result.add(InlineCode.text(code));
    position = to;
  }
  result.addAll(slice(position, total));
  return result;
}

// ---------------------------------------------------------------------------
// Runs of inline content -> nodes
// ---------------------------------------------------------------------------

/// Turns a run of inline content into nodes with (at most) one segment.
///
/// Whitespace, line breaks and comments at the edges, and a pair of codes
/// enclosing everything (`<b>…</b>`), stay outside the segment. When codes
/// that open and close elements remain inside, the translated content is
/// repaired with [repair] (see [repairInlineTags]) in case the engine
/// reordered or dropped them.
List<DocNode> inlineContent(
  DocumentBuilder builder,
  List<Inline> inlines, {
  String Function(String text)? escape,
  String? label,
  bool Function(String text)? accept,
  String lineBreak = '\n',
  String Function(String fragment)? repair,
}) {
  final items = [...inlines];
  final prefix = <DocNode>[];
  final suffix = <DocNode>[];

  bool isBlank(Inline item) => item is InlineText && item.text.trim().isEmpty;
  List<DocNode> nodesOf(Inline item) => switch (item) {
    InlineText(:final source) => [TextNode(source)],
    InlineCode(:final nodes) => nodes,
  };

  var changed = true;
  while (changed && items.isNotEmpty) {
    changed = false;
    while (items.isNotEmpty &&
        (isBlank(items.first) ||
            (items.first is InlineCode &&
                (items.first as InlineCode).movable))) {
      prefix.addAll(nodesOf(items.removeAt(0)));
      changed = true;
    }
    while (items.isNotEmpty &&
        (isBlank(items.last) ||
            (items.last is InlineCode && (items.last as InlineCode).movable))) {
      suffix.insertAll(0, nodesOf(items.removeLast()));
      changed = true;
    }
    if (items.length >= 2) {
      final first = items.first;
      final last = items.last;
      if (first is InlineCode &&
          last is InlineCode &&
          first.role == CodeRole.open &&
          last.role == CodeRole.close &&
          first.pair == last.pair &&
          _balancedInside(items)) {
        prefix.addAll(first.nodes);
        suffix.insertAll(0, last.nodes);
        items
          ..removeAt(0)
          ..removeLast();
        changed = true;
      }
    }
  }

  final pieces = <Piece>[
    for (final item in items)
      switch (item) {
        InlineText(:final source, :final text) => TextPiece(source, text),
        InlineCode(:final nodes) => TokenPiece(nodes),
      },
  ];
  final nodes = builder.content(
    pieces,
    escape: escape,
    label: label,
    accept: accept,
    lineBreak: lineBreak,
  );
  final paired = items.any(
    (item) => item is InlineCode && item.role != CodeRole.standalone,
  );
  if (repair == null || !paired || !hasSegment(nodes)) {
    return [...prefix, ...nodes, ...suffix];
  }
  final raw = identityText(nodes);
  // Malformed source markup (HTML) is left as it was.
  if (repair(raw) != raw) return [...prefix, ...nodes, ...suffix];
  return [
    ...prefix,
    EncodedNode(raw: raw, children: nodes, encode: repair),
    ...suffix,
  ];
}

/// Whether the codes strictly inside the first and last item of [items]
/// never close the pair those two form (so removing both keeps the run
/// balanced).
bool _balancedInside(List<Inline> items) {
  final pair = (items.first as InlineCode).pair;
  for (var i = 1; i < items.length - 1; i++) {
    final item = items[i];
    if (item is InlineCode && item.pair == pair) return false;
  }
  return true;
}

/// HTML elements without end tags.
const htmlVoidElements = {
  'area',
  'base',
  'br',
  'col',
  'embed',
  'hr',
  'img',
  'input',
  'keygen',
  'link',
  'meta',
  'param',
  'source',
  'track',
  'wbr',
};

/// Makes the inline tags of a translated [fragment] nest properly again:
/// end tags that close nothing open are dropped, and elements left open
/// are closed at the end. Text between tags is never touched.
String repairInlineTags(String fragment, {required bool html}) {
  final tokens = lexMarkup(fragment, html: html);
  final out = StringBuffer();
  final open = <String>[];
  String key(MarkupToken token) => html ? token.lowerName : token.name;
  var changed = false;
  for (final token in tokens) {
    switch (token.kind) {
      case MarkupKind.startTag:
        if (!token.selfClosing &&
            !(html && htmlVoidElements.contains(token.lowerName))) {
          open.add(token.name);
        }
      case MarkupKind.endTag:
        final name = key(token);
        if (open.isEmpty ||
            (html ? asciiLower(open.last) : open.last) != name) {
          final index = open.lastIndexWhere(
            (element) => (html ? asciiLower(element) : element) == name,
          );
          if (index < 0) {
            changed = true;
            continue;
          }
          // Close the elements opened after it first.
          for (var i = open.length - 1; i > index; i--) {
            out.write('</${open[i]}>');
          }
          open.removeRange(index + 1, open.length);
          changed = true;
        }
        open.removeLast();
      case MarkupKind.text ||
          MarkupKind.rawText ||
          MarkupKind.comment ||
          MarkupKind.cdata ||
          MarkupKind.processing ||
          MarkupKind.declaration:
        break;
    }
    out.write(token.raw(fragment));
  }
  for (var i = open.length - 1; i >= 0; i--) {
    out.write('</${open[i]}>');
    changed = true;
  }
  return changed ? out.toString() : fragment;
}

// ---------------------------------------------------------------------------
// Editing tags
// ---------------------------------------------------------------------------

/// Collects template nodes, merging adjacent text.
final class NodeList {
  final List<DocNode> nodes = [];

  void text(String text) {
    if (text.isEmpty) return;
    final previous = nodes.isEmpty ? null : nodes.last;
    if (previous is TextNode) {
      nodes[nodes.length - 1] = TextNode('${previous.text}$text');
    } else {
      nodes.add(TextNode(text));
    }
  }

  void addAll(Iterable<DocNode> items) {
    for (final node in items) {
      if (node is TextNode) {
        text(node.text);
      } else {
        nodes.add(node);
      }
    }
  }
}

/// The start tag [tag] of [source] with attributes set to [values] (an
/// existing attribute keeps its place and quotes; a new one is added after
/// the last attribute). Values are escaped.
String setAttributes(
  String source,
  MarkupToken tag,
  Map<String, String> values,
) {
  final edits = <({int start, int end, String text})>[];
  final missing = <String, String>{};
  for (final MapEntry(key: name, :value) in values.entries) {
    final attribute = tag.attribute(name, ignoreCase: true);
    if (attribute == null) {
      missing[name] = value;
    } else if (attribute.hasValue) {
      final quote = attribute.quote;
      final escaped = escapeMarkupAttribute(value, quote);
      edits.add(
        quote.isEmpty
            ? (
                start: attribute.valueStart,
                end: attribute.valueEnd,
                text: '"$escaped"',
              )
            : (
                start: attribute.valueStart,
                end: attribute.valueEnd,
                text: escaped,
              ),
      );
    } else {
      edits.add((
        start: attribute.end,
        end: attribute.end,
        text: '="${escapeMarkupAttribute(value, '"')}"',
      ));
    }
  }
  if (missing.isNotEmpty) {
    final at = tag.attributes.isEmpty
        ? tag.start + 1 + tag.name.length
        : tag.attributes.last.end;
    edits.add((
      start: at,
      end: at,
      text: [
        for (final MapEntry(key: name, :value) in missing.entries)
          ' $name="${escapeMarkupAttribute(value, '"')}"',
      ].join(),
    ));
  }
  edits.sort((a, b) => a.start.compareTo(b.start));
  final out = StringBuffer();
  var position = tag.start;
  for (final edit in edits) {
    out
      ..write(source.substring(position, edit.start))
      ..write(edit.text);
    position = edit.end;
  }
  out.write(source.substring(position, tag.end));
  return out.toString();
}

/// [children] (whose text starts with [oldPrefix]) rendered with
/// [newPrefix] in its place once anything inside them is translated.
List<DocNode> replacePrefixWhenTranslated(
  List<DocNode> children,
  String oldPrefix,
  String newPrefix,
) {
  if (oldPrefix == newPrefix || !hasSegment(children)) return children;
  return [
    EncodedNode(
      raw: identityText(children),
      children: children,
      encode: (rendered) => rendered.startsWith(oldPrefix)
          ? '$newPrefix${rendered.substring(oldPrefix.length)}'
          : rendered,
    ),
  ];
}

final _formatConversion = RegExp('^(?:${LocalisationPatterns.printf})\$');

/// Whether [inlines] hold a printf conversion as a code (so a literal `%`
/// in a translation must be written `%%`).
bool hasFormatConversion(List<Inline> inlines) => inlines.any(
  (item) =>
      item is InlineCode &&
      item.nodes.length == 1 &&
      item.nodes.single is TextNode &&
      _formatConversion.hasMatch((item.nodes.single as TextNode).text),
);
