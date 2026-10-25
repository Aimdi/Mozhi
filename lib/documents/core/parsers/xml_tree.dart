/// Safe reading of XML localisation files (XLIFF, Android strings): the
/// document is validated with `package:xml` (which never resolves DTDs or
/// external entities), entity declarations are refused, and the elements
/// are arranged in a tree that keeps every token's position.
library;

import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException;
import 'package:mozhi/documents/core/parsers/markup_content.dart';
import 'package:mozhi/documents/core/parsers/markup_lexer.dart';
import 'package:xml/xml.dart' show XmlException;
import 'package:xml/xml_events.dart';

/// Inputs longer than this (in UTF-16 code units) are refused.
const int maxMarkupLength = 16 * 1024 * 1024;

/// Elements nested deeper than this are refused.
const maxMarkupDepth = 256;

/// An element of an [XmlTree].
final class XmlElement {
  new(this.start, this.parent);

  final MarkupToken start;
  final XmlElement? parent;

  /// The end tag; null for an empty element (`<name/>`).
  MarkupToken? end;

  /// Child elements and other tokens (text, comments, CDATA, ...), in order.
  final List<Object> children = [];

  String get name => start.name;
  String get localName => start.localName;

  int get outerStart => start.start;
  int get outerEnd => (end ?? start).end;
  int get contentStart => start.end;
  int get contentEnd => end?.start ?? start.end;

  Iterable<XmlElement> get elements => children.whereType<XmlElement>();

  /// The first child element with local name [localName], or null.
  XmlElement? child(String localName) {
    for (final element in elements) {
      if (element.localName == localName) return element;
    }
    return null;
  }

  /// The decoded value of attribute [name] (exact name, e.g. `xml:lang`).
  String? attribute(String source, String name) {
    final attribute = start.attribute(name);
    if (attribute == null) return null;
    return decodeAttributeValue(attribute.rawValue(source), html: false);
  }

  /// Like [attribute], matching the attribute's local name (any prefix).
  String? localAttribute(String source, String localName) {
    for (final attribute in start.attributes) {
      final colon = attribute.name.indexOf(':');
      final local = colon < 0
          ? attribute.name
          : attribute.name.substring(colon + 1);
      if (local == localName && !attribute.name.startsWith('xmlns')) {
        return decodeAttributeValue(attribute.rawValue(source), html: false);
      }
    }
    return null;
  }

  /// The decoded text content of the element (descendants included).
  String textContent(String source) {
    final buffer = StringBuffer();
    void collect(XmlElement element) {
      for (final child in element.children) {
        switch (child) {
          case XmlElement():
            collect(child);
          case MarkupToken(kind: MarkupKind.text):
            buffer.write(decodeAttributeValue(child.raw(source), html: false));
          case MarkupToken(kind: MarkupKind.cdata):
            final raw = child.raw(source);
            buffer.write(raw.substring(9, raw.length - 3));
        }
      }
    }

    collect(this);
    return buffer.toString();
  }
}

/// A validated XML document.
final class XmlTree {
  const new({
    required this.source,
    required this.tokens,
    required this.root,
    required this.declaration,
  });

  final String source;
  final List<MarkupToken> tokens;
  final XmlElement root;

  /// The XML declaration (`<?xml ...?>`), if any.
  final MarkupToken? declaration;
}

/// Validates and reads [source] as XML; [format] names the file type in
/// error messages.
///
/// Throws [DocumentParseException] for malformed XML, a document type
/// declaration that declares entities, too long input or too deep nesting.
XmlTree parseXmlTree(String source, {required String format}) {
  if (source.length > maxMarkupLength) {
    throw DocumentParseException('$format: the file is too large');
  }
  var offset = 0;
  if (source.startsWith('\uFEFF')) offset = 1;
  while (offset < source.length && _isSpace(source.codeUnitAt(offset))) {
    offset++;
  }
  final tokens = lexMarkup(source, html: false, start: offset);
  for (final token in tokens) {
    if (token.kind == MarkupKind.declaration &&
        token.raw(source).contains('<!ENTITY')) {
      throw DocumentParseException(
        '$format: entity declarations are not supported',
      );
    }
  }
  _validate(source, offset, format);

  XmlElement? root;
  XmlElement? current;
  MarkupToken? declaration;
  var depth = 0;
  for (final token in tokens) {
    switch (token.kind) {
      case MarkupKind.startTag:
        final element = XmlElement(token, current);
        if (current == null) {
          root ??= element;
        } else {
          current.children.add(element);
        }
        if (!token.selfClosing) {
          current = element;
          depth++;
        }
      case MarkupKind.endTag:
        if (current == null || current.name != token.name) {
          // package:xml accepted it, so this cannot happen.
          // coverage:ignore-start
          throw DocumentParseException('$format: mismatched </${token.name}>');
          // coverage:ignore-end
        }
        current.end = token;
        current = current.parent;
        depth--;
      case MarkupKind.processing:
        if (current == null && root == null && declaration == null) {
          if (token.raw(source).startsWith('<?xml')) declaration = token;
        }
        current?.children.add(token);
      case MarkupKind.text ||
          MarkupKind.rawText ||
          MarkupKind.comment ||
          MarkupKind.cdata ||
          MarkupKind.declaration:
        current?.children.add(token);
    }
  }
  if (root == null) {
    // coverage:ignore-start
    throw DocumentParseException('$format: no root element');
    // coverage:ignore-end
  }
  assert(depth == 0, 'unbalanced document');
  return XmlTree(
    source: source,
    tokens: tokens,
    root: root,
    declaration: declaration,
  );
}

void _validate(String source, int offset, String format) {
  final input = offset == 0 ? source : source.substring(offset);
  var depth = 0;
  try {
    for (final event in parseEvents(
      input,
      validateNesting: true,
      validateDocument: true,
    )) {
      if (event is XmlStartElementEvent && !event.isSelfClosing) {
        depth++;
        if (depth > maxMarkupDepth) {
          throw DocumentParseException('$format: elements nested too deeply');
        }
      } else if (event is XmlEndElementEvent) {
        depth--;
      }
    }
  } on XmlException catch (error) {
    var location = '';
    if (error is FormatException) {
      final position = (error as FormatException).offset;
      if (position != null) {
        final before = source.substring(0, offset + position);
        final line = '\n'.allMatches(before).length + 1;
        final column = before.length - before.lastIndexOf('\n');
        location = ' (line $line, column $column)';
      }
    }
    throw DocumentParseException('$format: ${error.message}$location');
  }
}

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
