import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart';
import 'package:mozhi/documents/core/parsers/markup_lexer.dart';
import 'package:mozhi/documents/core/parsers/xliff_parser.dart'
    show utf8Declaration;
import 'package:mozhi/documents/core/parsers/xml_tree.dart';

/// Parses Android string resources ([DocumentFormat.androidStrings]).
///
/// Translated in place: `<string>`, the items of `<string-array>` and
/// `<plurals>` (each quantity on its own; the quantities of the source are
/// kept), and `<item type="string">`. Skipped: anything marked
/// `translatable="false"`, resource references (`@string/name`), values
/// that are not natural language, and every other resource type.
///
/// Android's escaping is read and written back: `\'`, `\"`, `\\`, `\@`,
/// `\?` and `\uXXXX` are decoded for the engine and escaped again, `\n`
/// and `\t` stay as placeholders, a value in double quotes keeps them, and
/// a translation starting with `@` or `?` is escaped. `<xliff:g>` (kept
/// whole), styling tags (`<b>`, `<i>`, `<a>`, `<annotation>`...), format
/// arguments (`%1$s`, `%d`) and CDATA content are protected; a literal `%`
/// in a translated format string is written as `%%`.
///
/// Throws [DocumentParseException] for malformed XML, entity declarations,
/// or a root element other than `<resources>`.
ParsedDocument parseAndroidStrings(String text) {
  final tree = parseXmlTree(text, format: 'Android strings');
  if (tree.root.localName != 'resources') {
    throw DocumentParseException(
      'Android strings: the root element is <${tree.root.name}>, '
      'not <resources>',
    );
  }
  return _AndroidParser(tree).parse();
}

/// Styling tags of string resources, translated with their content.
const _styleTags = {
  'a',
  'annotation',
  'b',
  'big',
  'em',
  'font',
  'i',
  'li',
  'small',
  'span',
  'strike',
  's',
  'strong',
  'sub',
  'sup',
  'tt',
  'u',
};

// `^[@?][\w.:+-]*/?[\w.$]+$` without its quadratic backtracking (the two
// runs overlap): the last part is a `/` and a name, one more name
// character, or a `$` and the rest.
final _reference = RegExp(r'^[@?][\w.:+-]*(?:/[\w.$]+|[\w.]|\$[\w.$]*)$');

class _AndroidParser {
  new(this.tree) : source = tree.source;

  final XmlTree tree;
  final String source;
  final DocumentBuilder builder = DocumentBuilder();
  int _pairs = 0;

  ParsedDocument parse() {
    final root = tree.root;
    var nodes = NodeList()..text(source.substring(0, root.outerStart));
    var position = root.outerStart;
    for (final child in root.elements) {
      nodes
        ..text(source.substring(position, child.outerStart))
        ..addAll(_resource(child));
      position = child.outerEnd;
    }
    nodes.text(source.substring(position));

    final declaration = tree.declaration;
    if (declaration != null) {
      final raw = declaration.raw(source);
      final fixed = utf8Declaration(raw);
      if (fixed != raw) {
        nodes = NodeList()
          ..addAll([
            EncodedNode(
              raw: source,
              children: nodes.nodes,
              encode: (rendered) => rendered.replaceFirst(raw, fixed),
            ),
          ]);
      }
    }
    builder.add(nodes.nodes);
    return builder.build(DocumentFormat.androidStrings);
  }

  String _outer(XmlElement element) =>
      source.substring(element.outerStart, element.outerEnd);

  List<DocNode> _resource(XmlElement element) {
    final whole = [TextNode(_outer(element))];
    if (element.attribute(source, 'translatable') == 'false') return whole;
    final name = element.attribute(source, 'name');
    switch (element.localName) {
      case 'string':
        return _value(element, label: name);
      case 'item' when element.attribute(source, 'type') == 'string':
        return _value(element, label: name);
      case 'string-array' || 'plurals':
        final plurals = element.localName == 'plurals';
        final nodes = NodeList();
        var position = element.outerStart;
        var index = 0;
        for (final item in element.elements) {
          nodes.text(source.substring(position, item.outerStart));
          if (item.localName == 'item') {
            final quantity = item.attribute(source, 'quantity');
            nodes.addAll(
              _value(
                item,
                label: plurals ? '$name:$quantity' : '$name[$index]',
              ),
            );
            index++;
          } else {
            nodes.text(_outer(item));
          }
          position = item.outerEnd;
        }
        nodes.text(source.substring(position, element.outerEnd));
        return nodes.nodes;
      default:
        return whole;
    }
  }

  /// Nodes for a string value element.
  List<DocNode> _value(XmlElement element, {String? label}) {
    if (element.end == null) return [TextNode(_outer(element))];
    final formatted = element.attribute(source, 'formatted') != 'false';
    final cdata = _cdataOnly(element);
    final List<Inline> inlines;
    final String Function(String text) escape;
    if (cdata != null) {
      final raw = cdata.raw(source);
      final inner = protectInlines(
        _escapedText(raw, 9, raw.length - 3, xml: false).items,
        LocalisationPatterns.resource,
      );
      inlines = [
        InlineText(source.substring(element.contentStart, cdata.start)),
        InlineCode.text('<![CDATA[', role: CodeRole.open, pair: _pairs),
        ...inner,
        InlineCode.text(']]>', role: CodeRole.close, pair: _pairs++),
        InlineText(source.substring(cdata.end, element.contentEnd)),
      ];
      final percent = formatted && hasFormatConversion(inner);
      escape = (text) => escapeCdata(
        _androidEscape(text, quoted: false, xml: false, percent: percent),
      );
    } else {
      final quoted = _quoted(element);
      final items = <Inline>[];
      for (final child in element.children) {
        items.addAll(_inline(child, quoted: quoted));
      }
      inlines = protectInlines(items, LocalisationPatterns.resource);
      final percent = formatted && hasFormatConversion(inlines);
      escape = (text) =>
          _androidEscape(text, quoted: quoted, xml: true, percent: percent);
    }

    final content = inlineContent(
      builder,
      inlines,
      escape: escape,
      label: label,
      accept: (text) =>
          looksLikeNaturalLanguage(text) && !_reference.hasMatch(text.trim()),
      repair: (fragment) => repairInlineTags(fragment, html: false),
    );
    final nodes = [
      TextNode(element.start.raw(source)),
      ...hasSegment(content)
          ? [
              EncodedNode(
                raw: identityText(content),
                children: content,
                encode: _escapeLeadingReference,
              ),
            ]
          : content,
      TextNode(element.end!.raw(source)),
    ];
    return nodes;
  }

  /// The CDATA section that is [element]'s only content (besides
  /// whitespace), or null.
  MarkupToken? _cdataOnly(XmlElement element) {
    MarkupToken? cdata;
    for (final child in element.children) {
      if (child is MarkupToken && child.kind == MarkupKind.cdata) {
        if (cdata != null) return null;
        cdata = child;
      } else if (child is! MarkupToken ||
          child.kind != MarkupKind.text ||
          child.raw(source).trim().isNotEmpty) {
        return null;
      }
    }
    return cdata;
  }

  /// Whether the value is wrapped in double quotes (whitespace kept,
  /// apostrophes need no escape).
  bool _quoted(XmlElement element) {
    final children = element.children;
    if (children.isEmpty) return false;
    final first = children.first;
    final last = children.last;
    if (first is! MarkupToken ||
        last is! MarkupToken ||
        first.kind != MarkupKind.text ||
        last.kind != MarkupKind.text) {
      return false;
    }
    final head = first.raw(source).trimLeft();
    final tail = last.raw(source).trimRight();
    if (!head.startsWith('"') || !tail.endsWith('"')) return false;
    if (identical(first, last) && head.trim().length < 2) return false;
    // Exactly two unescaped quotes in the whole value.
    var quotes = 0;
    for (final child in children) {
      if (child is! MarkupToken || child.kind != MarkupKind.text) continue;
      final raw = child.raw(source);
      for (var i = 0; i < raw.length; i++) {
        if (raw[i] == r'\') {
          i++;
        } else if (raw[i] == '"') {
          quotes++;
        }
      }
    }
    return quotes == 2 && !tail.endsWith(r'\"');
  }

  List<Inline> _inline(Object child, {required bool quoted}) {
    switch (child) {
      case MarkupToken(kind: MarkupKind.text):
        return _escapedText(
          source,
          child.start,
          child.end,
          quoted: quoted,
        ).items;
      case MarkupToken(kind: MarkupKind.comment || MarkupKind.processing):
        return [InlineCode.text(child.raw(source), movable: true)];
      case MarkupToken():
        return [InlineCode.text(child.raw(source))];
      case XmlElement():
        if (_styleTags.contains(child.localName) &&
            !child.name.contains(':') &&
            child.end != null) {
          final pair = _pairs++;
          return [
            InlineCode.text(
              child.start.raw(source),
              role: CodeRole.open,
              pair: pair,
            ),
            for (final inner in child.children)
              ..._inline(inner, quoted: quoted),
            InlineCode.text(
              child.end!.raw(source),
              role: CodeRole.close,
              pair: pair,
            ),
          ];
        }
        // <xliff:g> and anything unknown: kept whole.
        return [InlineCode.text(_outer(child))];
    }
    // coverage:ignore-start
    return const [];
    // coverage:ignore-end
  }
}

/// Android text between tags (or a CDATA section's content, from [start]
/// to [end] of [text]) as inline text and codes.
({List<Inline> items}) _escapedText(
  String text,
  int start,
  int end, {
  bool quoted = false,
  bool xml = true,
}) {
  final items = <Inline>[];
  final plain = StringBuffer();
  void flush() {
    if (plain.isEmpty) return;
    items.add(InlineText(plain.toString()));
    plain.clear();
  }

  var i = start;
  var inQuotes = false;
  while (i < end) {
    final char = text[i];
    if (char == '&' && xml) {
      final match = characterReference.matchAsPrefix(text, i);
      if (match != null && match.end <= end) {
        flush();
        items.addAll(textInlines(text, i, match.end, html: false));
        i = match.end;
        continue;
      }
    }
    if (char == r'\' && i + 1 < end) {
      final next = text[i + 1];
      flush();
      switch (next) {
        case "'" || '"' || r'\' || '@' || '?':
          items.add(InlineText('\\$next', next));
          i += 2;
        case 'u'
            when i + 6 <= end &&
                RegExp(r'^[0-9a-fA-F]{4}$')
                    .hasMatch(text.substring(i + 2, i + 6)):
          final raw = text.substring(i, i + 6);
          final decoded = String.fromCharCode(
            int.parse(text.substring(i + 2, i + 6), radix: 16),
          );
          items.add(
            decoded.trim().isEmpty || decoded.contains(_control)
                ? InlineCode.text(raw)
                : InlineText(raw, decoded),
          );
          i += 6;
        case 'n' || 't':
          items.add(InlineCode.text('\\$next', movable: true));
          i += 2;
        default:
          items.add(InlineCode.text(text.substring(i, i + 2)));
          i += 2;
      }
      continue;
    }
    if (char == '"') {
      flush();
      // The quotes around a quoted value stay outside the segment.
      items.add(
        InlineCode.text(
          '"',
          role: quoted
              ? (inQuotes ? CodeRole.close : CodeRole.open)
              : CodeRole.standalone,
          pair: quoted ? -2 : -1,
        ),
      );
      inQuotes = !inQuotes;
      i++;
      continue;
    }
    if (!quoted && _isSpace(text.codeUnitAt(i))) {
      var j = i;
      while (j < end && _isSpace(text.codeUnitAt(j))) {
        j++;
      }
      final run = text.substring(i, j);
      if (run == ' ') {
        plain.write(' ');
      } else {
        flush();
        items.add(InlineText(run, ' '));
      }
      i = j;
      continue;
    }
    plain.write(char);
    i++;
  }
  flush();
  return (items: items);
}

final _control = RegExp(r'\p{C}', unicode: true);

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

/// Escapes translated text for a string resource.
String _androidEscape(
  String text, {
  required bool quoted,
  required bool xml,
  required bool percent,
}) {
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    switch (char) {
      case r'\':
        out.write(r'\\');
      case '"':
        out.write(r'\"');
      case "'":
        out.write(quoted ? "'" : r"\'");
      case '\n':
        out.write(r'\n');
      case '\t':
        out.write(r'\t');
      case '%' when percent:
        out.write('%%');
      case '&' when xml:
        out.write('&amp;');
      case '<' when xml:
        out.write('&lt;');
      case '>' when xml:
        out.write('&gt;');
      default:
        out.write(char);
    }
  }
  return out.toString();
}

/// A value starting with `@` or `?` would be read as a reference.
String _escapeLeadingReference(String value) {
  final trimmed = value.trimLeft();
  if (trimmed.startsWith('@') || trimmed.startsWith('?')) {
    final at = value.length - trimmed.length;
    return '${value.substring(0, at)}\\${value.substring(at)}';
  }
  return value;
}
