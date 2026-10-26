import 'package:mozhi/documents/core/office/package_errors.dart';
import 'package:xml/xml.dart' show XmlEntityMapping, XmlParserException;
import 'package:xml/xml_events.dart';

/// Namespace URIs of the XML vocabularies the office parsers read.
abstract final class Ns {
  static const xml = 'http://www.w3.org/XML/1998/namespace';

  // Office Open XML (transitional and strict).
  static const word = {
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
    'http://purl.oclc.org/ooxml/wordprocessingml/main',
  };
  static const drawing = {
    'http://schemas.openxmlformats.org/drawingml/2006/main',
    'http://purl.oclc.org/ooxml/drawingml/main',
  };
  static const sheet = {
    'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
    'http://purl.oclc.org/ooxml/spreadsheetml/main',
  };
  static const relationships = {
    'http://schemas.openxmlformats.org/package/2006/relationships',
  };
  static const contentTypes = {
    'http://schemas.openxmlformats.org/package/2006/content-types',
  };
  static const dublinCore = {'http://purl.org/dc/elements/1.1/'};

  // OpenDocument.
  static const odfOffice = {'urn:oasis:names:tc:opendocument:xmlns:office:1.0'};
  static const odfText = {'urn:oasis:names:tc:opendocument:xmlns:text:1.0'};
  static const odfTable = {'urn:oasis:names:tc:opendocument:xmlns:table:1.0'};
  static const odfStyle = {'urn:oasis:names:tc:opendocument:xmlns:style:1.0'};
  static const odfFo = {
    'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0',
  };
  static const odfManifest = {
    'urn:oasis:names:tc:opendocument:xmlns:manifest:1.0',
  };
  static const calcExt = {
    'urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0',
  };

  // EPUB.
  static const xhtml = {'http://www.w3.org/1999/xhtml'};
  static const opf = {'http://www.idpf.org/2007/opf'};
  static const container = {'urn:oasis:names:tc:opendocument:xmlns:container'};
  static const ncx = {'http://www.daisy.org/z3986/2005/ncx/'};
  static const xmlEncryption = {'http://www.w3.org/2001/04/xmlenc#'};
}

/// A node of a parsed XML part, with its position in the source text.
sealed class SourceNode {
  new(this.start, this.end);

  /// Offset of the first character of the node in the source.
  final int start;

  /// Offset just after the node.
  int end;
}

/// An attribute with its resolved namespace.
final class SourceAttribute {
  const new({
    required this.qualifiedName,
    required this.localName,
    required this.namespace,
    required this.value,
    required this.quote,
  });

  final String qualifiedName;
  final String localName;
  final String? namespace;

  /// The decoded value.
  final String value;
  final XmlAttributeType quote;
}

/// An element and its children.
final class SourceElement extends SourceNode {
  new({
    required int start,
    required this.qualifiedName,
    required this.localName,
    required this.prefix,
    required this.namespace,
    required this.attributes,
    required this.startTagEnd,
    required this.parent,
  }) : endTagStart = startTagEnd,
       super(start, startTagEnd);

  final String qualifiedName;
  final String localName;

  /// Namespace prefix of the element name (null without one).
  final String? prefix;

  /// Resolved namespace URI (null when the element has none).
  final String? namespace;
  final List<SourceAttribute> attributes;

  /// Offset just after the start tag (`end` for a self-closing element).
  final int startTagEnd;

  /// Offset of the end tag (`end` for a self-closing element).
  int endTagStart;
  final SourceElement? parent;
  final List<SourceNode> children = [];

  bool get isSelfClosing => startTagEnd == end;

  /// Whether this is the element [local] in one of [namespaces].
  bool isA(Set<String> namespaces, String local) =>
      localName == local && namespaces.contains(namespace);

  /// Whether the element belongs to one of [namespaces].
  bool inNamespace(Set<String> namespaces) => namespaces.contains(namespace);

  /// The value of the attribute [local] in one of [namespaces] (or without
  /// namespace when [namespaces] is null).
  String? attribute(String local, [Set<String>? namespaces]) {
    for (final attribute in attributes) {
      if (attribute.localName != local) continue;
      if (namespaces == null
          ? attribute.namespace == null
          : namespaces.contains(attribute.namespace)) {
        return attribute.value;
      }
    }
    return null;
  }

  /// Element children.
  Iterable<SourceElement> get elements => children.whereType<SourceElement>();

  /// The first child element [local] in one of [namespaces].
  SourceElement? child(Set<String> namespaces, String local) {
    for (final element in elements) {
      if (element.isA(namespaces, local)) return element;
    }
    return null;
  }

  /// All descendant elements, depth first in document order.
  Iterable<SourceElement> get descendants sync* {
    for (final element in elements) {
      yield element;
      yield* element.descendants;
    }
  }

  /// The decoded text of all descendant text nodes.
  String get text {
    final buffer = StringBuffer();
    void collect(SourceElement element) {
      for (final node in element.children) {
        switch (node) {
          case SourceText(:final value):
            buffer.write(value);
          case SourceElement():
            collect(node);
          case SourceMisc():
            break;
        }
      }
    }

    collect(this);
    return buffer.toString();
  }

  @override
  String toString() => 'SourceElement($qualifiedName)';
}

/// Character data (text or CDATA).
final class SourceText extends SourceNode {
  new(super.start, super.end, this.value, {this.isCData = false});

  /// The decoded text.
  final String value;
  final bool isCData;
}

/// A comment or processing instruction.
final class SourceMisc extends SourceNode {
  new(super.start, super.end);
}

/// A parsed XML part: its [source] text and [root] element.
final class SourceDocument {
  const new(this.source, this.root);

  /// Parses [source] defensively: no document type declaration unless
  /// [allowDoctype] (and never one with an internal subset, which could
  /// declare entities), at most [maxDepth] nested elements, well-formed
  /// nesting and a single root element.
  ///
  /// Entities are never resolved beyond [entities] (by default the five
  /// predefined XML ones and character references); nothing is fetched.
  ///
  /// Throws [PackageParseException].
  factory parse(
    String source, {
    required String part,
    bool allowDoctype = false,
    int maxDepth = 256,
    XmlEntityMapping? entities,
  }) {
    SourceElement? root;
    final stack = <SourceElement>[];
    final scopes = <Map<String, String>>[
      const {'xml': Ns.xml},
    ];
    Never damaged(String reason) =>
        throw PackageParseException(PackageProblem.damaged, '$part: $reason');

    try {
      for (final event in parseEvents(
        source,
        withLocation: true,
        entityMapping: entities,
      )) {
        final start = event.start!;
        final stop = event.stop!;
        switch (event) {
          case XmlDoctypeEvent(:final internalSubset):
            if (!allowDoctype || internalSubset != null) {
              throw PackageParseException(
                PackageProblem.unsafe,
                '$part: document type declarations are not allowed',
              );
            }
            if (root != null) damaged('misplaced doctype');
          case XmlStartElementEvent(
            :final name,
            :final attributes,
            :final isSelfClosing,
          ):
            if (stack.isEmpty && root != null) damaged('several roots');
            if (stack.length >= maxDepth) {
              throw PackageParseException(
                PackageProblem.unsafe,
                '$part: elements are nested too deeply',
              );
            }
            var scope = scopes.last;
            for (final attribute in attributes) {
              final attributeName = attribute.name;
              if (attributeName == 'xmlns') {
                scope = {...scope, '': attribute.value};
              } else if (attributeName.startsWith('xmlns:')) {
                scope = {...scope, attributeName.substring(6): attribute.value};
              }
            }
            final (prefix, local) = _split(name);
            final parent = stack.isEmpty ? null : stack.last;
            final element = SourceElement(
              start: start,
              qualifiedName: name,
              localName: local,
              prefix: prefix,
              namespace: scope[prefix ?? ''],
              attributes: [
                for (final attribute in attributes)
                  _attribute(attribute, scope),
              ],
              startTagEnd: stop,
              parent: parent,
            );
            if (parent == null) {
              root = element;
            } else {
              parent.children.add(element);
            }
            if (!isSelfClosing) {
              stack.add(element);
              scopes.add(scope);
            }
          case XmlEndElementEvent(:final name):
            if (stack.isEmpty || stack.last.qualifiedName != name) {
              damaged('mismatched end tag </$name>');
            }
            stack.removeLast()
              ..endTagStart = start
              ..end = stop;
            scopes.removeLast();
          case XmlTextEvent(:final value):
            if (stack.isEmpty) {
              if (value.trim().isNotEmpty) damaged('text outside the root');
            } else {
              stack.last.children.add(SourceText(start, stop, value));
            }
          case XmlCDATAEvent(:final value):
            if (stack.isEmpty) damaged('CDATA outside the root');
            stack.last.children.add(
              SourceText(start, stop, value, isCData: true),
            );
          case XmlCommentEvent() || XmlProcessingEvent():
            if (stack.isNotEmpty) {
              stack.last.children.add(SourceMisc(start, stop));
            }
          case XmlDeclarationEvent():
            if (root != null) damaged('misplaced declaration');
        }
      }
    } on XmlParserException catch (error) {
      damaged(error.message);
    }
    if (stack.isNotEmpty) damaged('unclosed <${stack.last.qualifiedName}>');
    final document = root;
    if (document == null) damaged('no root element');
    return SourceDocument(source, document);
  }

  final String source;
  final SourceElement root;

  /// Source text of [node].
  String of(SourceNode node) => source.substring(node.start, node.end);

  static (String?, String) _split(String name) {
    final colon = name.indexOf(':');
    return colon < 0
        ? (null, name)
        : (name.substring(0, colon), name.substring(colon + 1));
  }

  static SourceAttribute _attribute(
    XmlEventAttribute attribute,
    Map<String, String> scope,
  ) {
    final (prefix, local) = _split(attribute.name);
    return SourceAttribute(
      qualifiedName: attribute.name,
      localName: local,
      // Unprefixed attributes have no namespace.
      namespace: prefix == null ? null : scope[prefix],
      value: attribute.value,
      quote: attribute.attributeType,
    );
  }
}

/// Escapes [text] for XML character data, dropping characters XML 1.0
/// cannot hold.
String escapeXmlText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    switch (rune) {
      case 0x26:
        buffer.write('&amp;');
      case 0x3C:
        buffer.write('&lt;');
      case 0x3E:
        buffer.write('&gt;');
      default:
        if (_isXmlChar(rune)) buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Escapes [value] for an attribute quoted with [quote].
String escapeXmlAttribute(String value, XmlAttributeType quote) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x26:
        buffer.write('&amp;');
      case 0x3C:
        buffer.write('&lt;');
      case 0x22 when quote == XmlAttributeType.DOUBLE_QUOTE:
        buffer.write('&quot;');
      case 0x27 when quote == XmlAttributeType.SINGLE_QUOTE:
        buffer.write('&apos;');
      case 0x09 || 0x0A || 0x0D:
        buffer.write('&#x${rune.toRadixString(16).toUpperCase()};');
      default:
        if (_isXmlChar(rune)) buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

bool _isXmlChar(int rune) =>
    rune == 0x09 ||
    rune == 0x0A ||
    rune == 0x0D ||
    (rune >= 0x20 && rune <= 0xD7FF) ||
    (rune >= 0xE000 && rune <= 0xFFFD) ||
    (rune >= 0x10000 && rune <= 0x10FFFF);
