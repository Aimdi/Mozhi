import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/icu_inlines.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/markup_content.dart';
import 'package:mozhi/documents/core/parsers/markup_lexer.dart';
import 'package:mozhi/documents/core/parsers/xml_tree.dart';

/// Parses XLIFF 1.2 and 2.x ([DocumentFormat.xliff]); [targetLanguage] becomes
/// the file's target language.
///
/// Each `<source>` that has no translation yet is translated into its
/// `<target>`: XLIFF 1.2 gets `<target state="needs-review-translation">`
/// after the source, XLIFF 2.x a `<target>` in the `<segment>`, which is
/// marked `state="translated"`. An XLIFF 1.2 unit whose `<seg-source>`
/// splits it into sentences (`<mrk mtype="seg">`) is translated sentence
/// by sentence, and its target has the same `<mrk>` segments. Existing
/// translations are kept, unless the file's target language
/// (`target-language`, `trgLang`) is another language than
/// [targetLanguage]: then every unit is translated again.
/// `translate="no"` (on files, groups, units, and inline `<mrk>`) is
/// respected; inline codes (`<g>`, `<x/>`, `<ph>`, `<pc>`, `<sc/>`, ...)
/// become placeholders, ICU plurals/selects keep their structure, and
/// printf/brace placeholders and escaped markup are protected.
///
/// Throws [DocumentParseException] for malformed XML, entity
/// declarations, or a root element other than `<xliff>`.
ParsedDocument parseXliff(String text, {String? targetLanguage}) {
  final tree = parseXmlTree(text, format: 'XLIFF');
  if (tree.root.localName != 'xliff') {
    throw DocumentParseException(
      'XLIFF: the root element is <${tree.root.name}>, not <xliff>',
    );
  }
  return _XliffParser(tree, canonicalLanguageTag(targetLanguage)).parse();
}

/// Paired inline elements whose content is translated with the sentence.
const _paired12 = {'g', 'mrk'};
const _paired20 = {'pc', 'mrk'};

class _XliffParser {
  new(this.tree, this.target) : source = tree.source, v2 = _isVersion2(tree);

  final XmlTree tree;
  final String source;
  final String? target;
  final bool v2;
  final DocumentBuilder builder = DocumentBuilder();
  int _pairs = 0;

  static bool _isVersion2(XmlTree tree) {
    final root = tree.root;
    final version = root.attribute(tree.source, 'version') ?? '';
    final namespace = root.attribute(tree.source, 'xmlns') ?? '';
    return version.startsWith('2') || namespace.contains('xliff:document:2');
  }

  ParsedDocument parse() {
    final root = tree.root;
    var nodes = NodeList()
      ..text(source.substring(0, root.outerStart))
      ..addAll(_element(root, retranslate: false))
      ..text(source.substring(root.outerEnd));
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
    return builder.build(DocumentFormat.xliff);
  }

  /// Nodes for [element] and its content.
  List<DocNode> _element(XmlElement element, {required bool retranslate}) {
    final name = element.localName;
    if (element.attribute(source, 'translate') == 'no') {
      return [TextNode(_outer(element))];
    }
    if (!v2 && name == 'trans-unit') {
      return _unit12(element, retranslate: retranslate);
    }
    if (v2 && name == 'segment') {
      return _segment20(element, retranslate: retranslate);
    }
    if (!v2 && name == 'xliff') {
      return _children(element, retranslate: retranslate);
    }
    if (!v2 && name == 'file') {
      final existing = element.attribute(source, 'target-language');
      final children = _children(
        element,
        retranslate: _otherLanguage(existing),
      );
      return _retarget(element, children, 'target-language');
    }
    if (v2 && name == 'xliff') {
      final existing = element.attribute(source, 'trgLang');
      final children = _children(
        element,
        retranslate: _otherLanguage(existing),
      );
      return _retarget(element, children, 'trgLang');
    }
    // Skeletons, notes, metadata, original data and alternative
    // translations hold no units of their own.
    if (const {
      'header',
      'skeleton',
      'notes',
      'note',
      'originalData',
      'alt-trans',
      'ignorable',
    }.contains(name)) {
      return [TextNode(_outer(element))];
    }
    return _children(element, retranslate: retranslate);
  }

  bool _otherLanguage(String? existing) =>
      target != null &&
      existing != null &&
      existing.trim().isNotEmpty &&
      !sameLanguage(existing, target!);

  List<DocNode> _retarget(
    XmlElement element,
    List<DocNode> children,
    String attribute,
  ) {
    final language = target;
    if (language == null) return children;
    final oldTag = element.start.raw(source);
    final newTag = setAttributes(source, element.start, {attribute: language});
    return replacePrefixWhenTranslated(children, oldTag, newTag);
  }

  String _outer(XmlElement element) =>
      source.substring(element.outerStart, element.outerEnd);

  /// [element]'s tags verbatim, its child elements through [_element].
  List<DocNode> _children(XmlElement element, {required bool retranslate}) {
    final nodes = NodeList();
    var position = element.outerStart;
    for (final child in element.elements) {
      nodes
        ..text(source.substring(position, child.outerStart))
        ..addAll(_element(child, retranslate: retranslate));
      position = child.outerEnd;
    }
    nodes.text(source.substring(position, element.outerEnd));
    return nodes.nodes;
  }

  // -------------------------------------------------------------------------
  // XLIFF 1.2
  // -------------------------------------------------------------------------

  List<DocNode> _unit12(XmlElement unit, {required bool retranslate}) {
    final whole = [TextNode(_outer(unit))];
    final sourceElement = unit.child('source');
    if (sourceElement == null) return whole;
    final targetElement = unit.child('target');
    final state = targetElement?.attribute(source, 'state');
    final untranslated =
        targetElement == null ||
        _isEmpty(targetElement) ||
        state == 'new' ||
        state == 'needs-translation';
    if (!untranslated && !retranslate) return whole;

    final label = unit.attribute(source, 'id');
    final segSource = unit.child('seg-source');
    final content =
        (segSource == null ? null : _segmented(segSource, label)) ??
        _content(sourceElement, label: label);
    if (!hasSegment(content)) return whole;

    const state12 = 'needs-review-translation';
    final int start;
    final int end;
    final String Function(String inner) wrap;
    if (targetElement != null) {
      start = targetElement.outerStart;
      end = targetElement.outerEnd;
      wrap = _targetWrapper(targetElement, {'state': state12});
    } else {
      // After <source> (and a <seg-source> that follows it).
      var after = sourceElement;
      if (segSource != null && segSource.outerStart > after.outerStart) {
        after = segSource;
      }
      start = after.outerEnd;
      end = start;
      final indent = _indentBefore(unit, sourceElement);
      final prefix = sourceElement.name.contains(':')
          ? sourceElement.name.substring(0, sourceElement.name.indexOf(':') + 1)
          : '';
      wrap = (inner) =>
          '$indent<${prefix}target state="$state12">$inner</${prefix}target>';
    }
    return [
      TextNode(source.substring(unit.outerStart, start)),
      EncodedNode(
        raw: source.substring(start, end),
        children: content,
        encode: wrap,
      ),
      TextNode(source.substring(end, unit.outerEnd)),
    ];
  }

  /// The content of a `<seg-source>` whose sentences are marked
  /// (`<mrk mtype="seg" mid="1">`): each marked sentence is a segment of
  /// its own, and the target gets the same markers around the
  /// translations, with whatever is between them kept. Null when it marks
  /// no sentences.
  List<DocNode>? _segmented(XmlElement segSource, String? label) {
    if (segSource.end == null) return null;
    bool isSentence(XmlElement element) =>
        element.localName == 'mrk' &&
        element.attribute(source, 'mtype') == 'seg' &&
        element.end != null;
    if (!segSource.elements.any(isSentence)) return null;
    final nodes = NodeList();
    var position = segSource.contentStart;
    for (final mark in segSource.elements.where(isSentence)) {
      final id = mark.attribute(source, 'mid');
      nodes
        ..text(source.substring(position, mark.outerStart))
        ..text(mark.start.raw(source))
        ..addAll(
          _content(mark, label: [label, id].whereType<String>().join('/')),
        )
        ..text(mark.end!.raw(source));
      position = mark.outerEnd;
    }
    nodes.text(source.substring(position, segSource.contentEnd));
    return nodes.nodes;
  }

  // -------------------------------------------------------------------------
  // XLIFF 2.x
  // -------------------------------------------------------------------------

  List<DocNode> _segment20(XmlElement segment, {required bool retranslate}) {
    final whole = [TextNode(_outer(segment))];
    final sourceElement = segment.child('source');
    if (sourceElement == null) return whole;
    final targetElement = segment.child('target');
    final state = segment.attribute(source, 'state');
    final untranslated =
        targetElement == null || _isEmpty(targetElement) || state == 'initial';
    if (!untranslated && !retranslate) return whole;

    final unitId = segment.parent?.attribute(source, 'id');
    final segmentId = segment.attribute(source, 'id');
    final content = _content(
      sourceElement,
      label: [unitId, segmentId].whereType<String>().join('/'),
    );
    if (!hasSegment(content)) return whole;

    final int start;
    final int end;
    final String Function(String inner) wrap;
    if (targetElement != null) {
      start = targetElement.outerStart;
      end = targetElement.outerEnd;
      wrap = _targetWrapper(targetElement, const {});
    } else {
      start = sourceElement.outerEnd;
      end = start;
      final indent = _indentBefore(segment, sourceElement);
      final prefix = sourceElement.name.contains(':')
          ? sourceElement.name.substring(0, sourceElement.name.indexOf(':') + 1)
          : '';
      wrap = (inner) => '$indent<${prefix}target>$inner</${prefix}target>';
    }
    final children = [
      TextNode(source.substring(segment.outerStart, start)),
      EncodedNode(
        raw: source.substring(start, end),
        children: content,
        encode: wrap,
      ),
      TextNode(source.substring(end, segment.outerEnd)),
    ];
    final oldTag = segment.start.raw(source);
    final newTag = setAttributes(source, segment.start, {
      'state': 'translated',
    });
    return replacePrefixWhenTranslated(children, oldTag, newTag);
  }

  // -------------------------------------------------------------------------
  // Shared
  // -------------------------------------------------------------------------

  /// Rebuilds an existing target element around translated content.
  String Function(String inner) _targetWrapper(
    XmlElement element,
    Map<String, String> attributes,
  ) {
    var startTag = setAttributes(source, element.start, attributes);
    final language = target;
    if (language != null && element.start.attribute('xml:lang') != null) {
      startTag = setAttributes(source, element.start, {
        ...attributes,
        'xml:lang': language,
      });
    }
    if (element.end == null) {
      // <target/>: open it.
      final slash = startTag.lastIndexOf('/');
      final open = '${startTag.substring(0, slash).trimRight()}>';
      return (inner) => '$open$inner</${element.name}>';
    }
    final endTag = element.end!.raw(source);
    return (inner) => '$startTag$inner$endTag';
  }

  /// The whitespace before [child] inside [parent] when it starts a new
  /// line (used to indent a new sibling), else nothing.
  String _indentBefore(XmlElement parent, XmlElement child) {
    final index = parent.children.indexOf(child);
    if (index <= 0) return '';
    final previous = parent.children[index - 1];
    if (previous is! MarkupToken || previous.kind != MarkupKind.text) {
      return '';
    }
    final raw = previous.raw(source);
    final newline = raw.lastIndexOf('\n');
    if (newline < 0 || raw.trim().isNotEmpty) return '';
    final lineStart = newline > 0 && raw[newline - 1] == '\r'
        ? newline - 1
        : newline;
    return raw.substring(lineStart);
  }

  bool _isEmpty(XmlElement element) =>
      element.elements.isEmpty && element.textContent(source).trim().isEmpty;

  /// The segment nodes for the content of [element] (a `<source>`).
  List<DocNode> _content(XmlElement element, {String? label}) {
    final cdata = _cdataOnly(element);
    if (cdata != null) {
      final raw = cdata.raw(source);
      final inner = protectInlines([
        InlineText(raw.substring(9, raw.length - 3)),
      ], LocalisationPatterns.text);
      return [
        TextNode(source.substring(element.contentStart, cdata.start + 9)),
        ...inlineContent(
          builder,
          inner,
          escape: escapeCdata,
          label: label,
          accept: looksLikeNaturalLanguage,
        ),
        TextNode(source.substring(cdata.end - 3, element.contentEnd)),
      ];
    }
    final inlines = icuInlines(
      _inlines(element),
      builder,
      (variant) => _segment(variant, label),
    );
    return _segment(inlines, label);
  }

  List<DocNode> _segment(List<Inline> inlines, String? label) => inlineContent(
    builder,
    protectInlines(inlines, LocalisationPatterns.text),
    escape: escapeMarkupText,
    label: label,
    accept: looksLikeNaturalLanguage,
    repair: (fragment) => repairInlineTags(fragment, html: false),
  );

  /// The CDATA section that is [element]'s only content (besides
  /// whitespace), or null.
  MarkupToken? _cdataOnly(XmlElement element) {
    MarkupToken? cdata;
    for (final child in element.children) {
      if (child is MarkupToken && child.kind == MarkupKind.cdata) {
        if (cdata != null) return null;
        cdata = child;
      } else if (child is MarkupToken &&
          child.kind == MarkupKind.text &&
          child.raw(source).trim().isEmpty) {
        continue;
      } else {
        return null;
      }
    }
    return cdata;
  }

  /// [element]'s content as inline text and codes.
  List<Inline> _inlines(XmlElement element) {
    final items = <Inline>[];
    final paired = v2 ? _paired20 : _paired12;
    for (final child in element.children) {
      switch (child) {
        case MarkupToken(kind: MarkupKind.text):
          items.addAll(
            textInlines(source, child.start, child.end, html: false),
          );
        case MarkupToken(kind: MarkupKind.comment || MarkupKind.processing):
          items.add(InlineCode.text(child.raw(source), movable: true));
        case MarkupToken():
          items.add(InlineCode.text(child.raw(source)));
        case XmlElement():
          final protected =
              child.attribute(source, 'translate') == 'no' ||
              child.attribute(source, 'mtype') == 'protected';
          if (paired.contains(child.localName) &&
              child.end != null &&
              !protected) {
            final pair = _pairs++;
            items
              ..add(
                InlineCode.text(
                  child.start.raw(source),
                  role: CodeRole.open,
                  pair: pair,
                ),
              )
              ..addAll(_inlines(child))
              ..add(
                InlineCode.text(
                  child.end!.raw(source),
                  role: CodeRole.close,
                  pair: pair,
                ),
              );
          } else {
            items.add(InlineCode.text(_outer(child)));
          }
      }
    }
    return items;
  }
}

/// [declaration] (`<?xml ... encoding="ISO-8859-1"?>`) declaring UTF-8
/// when it names another encoding than UTF-8/UTF-16 (translations are
/// written as Unicode).
String utf8Declaration(String declaration) {
  final match = _encoding.firstMatch(declaration);
  if (match == null) return declaration;
  final name = asciiLower(match.group(2)!.trim());
  if (name.startsWith('utf-8') || name.startsWith('utf-16') || name == 'utf8') {
    return declaration;
  }
  return declaration.replaceRange(
    match.start,
    match.end,
    'encoding=${match.group(1)}UTF-8${match.group(1)}',
  );
}

final _encoding = RegExp(r'''encoding\s*=\s*(["'])([^"']*)\1''');
