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

/// Parses TMX (Translation Memory eXchange) XML files ([DocumentFormat.tmx]).
///
/// Extracts `<seg>` content from source `<tuv>` units inside each `<tu>` in
/// `<body>`. Inline TMX tags (`<bpt>`, `<ept>`, `<ph>`, `<it>`, `<ut>`) are
/// protected as immutable placeholders, while `<hi>` wraps translatable text
/// with paired tags preserved.
///
/// When [targetLanguage] is provided:
/// - If a `<tu>` already has a `<tuv>` for [targetLanguage] with non-empty
///   `<seg>`, that unit is kept verbatim.
/// - If it has a `<tuv>` for [targetLanguage] with an empty `<seg>` (or
///   `<seg/>`), that `<seg>` is populated with the translation.
/// - Otherwise a new `<tuv xml:lang="...">` with the translated `<seg>` is
///   inserted cleanly after the last `<tuv>`, matching the file's indentation.
///
/// Without [targetLanguage], the source `<tuv>`'s `<seg>` is translated in
/// place.
///
/// Throws [DocumentParseException] for malformed XML, entity declarations,
/// or a root element other than `<tmx>`.
ParsedDocument parseTmx(String text, {String? targetLanguage}) {
  final tree = parseXmlTree(text, format: 'TMX');
  if (tree.root.localName != 'tmx') {
    throw DocumentParseException(
      'TMX: the root element is <${tree.root.name}>, not <tmx>',
    );
  }
  return _TmxParser(tree, canonicalLanguageTag(targetLanguage)).parse();
}

class _TmxParser {
  new(this.tree, this.target) : source = tree.source;

  final XmlTree tree;
  final String source;
  final String? target;
  final DocumentBuilder builder = DocumentBuilder();
  int _pairs = 0;

  ParsedDocument parse() {
    final root = tree.root;
    final header = root.child('header');
    final rawSrcLang = header?.attribute(source, 'srclang')?.trim();
    final srcLang =
        (rawSrcLang == null || rawSrcLang.isEmpty || rawSrcLang == '*all*')
        ? null
        : rawSrcLang;

    final body = root.child('body');
    var nodes = NodeList();
    if (body == null) {
      nodes.text(source);
    } else {
      nodes.text(source.substring(0, body.outerStart));
      var position = body.outerStart;
      for (final child in body.elements) {
        nodes
          ..text(source.substring(position, child.outerStart))
          ..addAll(
            child.localName == 'tu'
                ? _tu(child, srcLang: srcLang)
                : [TextNode(_outer(child))],
          );
        position = child.outerEnd;
      }
      nodes.text(source.substring(position));
    }

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
    return builder.build(DocumentFormat.tmx);
  }

  String _outer(XmlElement element) =>
      source.substring(element.outerStart, element.outerEnd);

  String? _tuvLang(XmlElement tuv) =>
      tuv.attribute(source, 'xml:lang') ?? tuv.attribute(source, 'lang');

  List<DocNode> _tu(XmlElement tu, {required String? srcLang}) {
    final whole = [TextNode(_outer(tu))];
    final tuvs = [
      for (final child in tu.elements)
        if (child.localName == 'tuv') child,
    ];
    if (tuvs.isEmpty) return whole;

    XmlElement? sourceTuv;
    if (srcLang != null) {
      for (final tuv in tuvs) {
        final lang = _tuvLang(tuv);
        if (lang != null && sameLanguage(lang, srcLang)) {
          sourceTuv = tuv;
          break;
        }
      }
    }
    sourceTuv ??= tuvs.first;

    final sourceSeg = sourceTuv.child('seg');
    if (sourceSeg == null || _isEmpty(sourceSeg)) return whole;

    final label = tu.attribute(source, 'tuid');
    final targetLang = target;

    if (targetLang == null) {
      // No target language specified: translate source <seg> in place.
      final content = _segContent(sourceSeg, label: label);
      if (!hasSegment(content)) return whole;
      return [
        TextNode(source.substring(tu.outerStart, sourceSeg.contentStart)),
        ...content,
        TextNode(source.substring(sourceSeg.contentEnd, tu.outerEnd)),
      ];
    }

    // Check whether a <tuv> for targetLang already exists.
    XmlElement? targetTuv;
    for (final tuv in tuvs) {
      final lang = _tuvLang(tuv);
      if (lang != null && sameLanguage(lang, targetLang)) {
        targetTuv = tuv;
        break;
      }
    }

    if (targetTuv != null) {
      // If it already has a non-empty <seg>, keep existing translation.
      final targetSeg = targetTuv.child('seg');
      if (targetSeg != null && !_isEmpty(targetSeg)) return whole;

      final content = _segContent(sourceSeg, label: label);
      if (!hasSegment(content)) return whole;

      if (targetSeg != null) {
        final wrap = _segWrapper(targetSeg);
        return [
          TextNode(source.substring(tu.outerStart, targetSeg.outerStart)),
          EncodedNode(raw: _outer(targetSeg), children: content, encode: wrap),
          TextNode(source.substring(targetSeg.outerEnd, tu.outerEnd)),
        ];
      }
      // Target <tuv> exists without a <seg> element.
      if (targetTuv.end == null) {
        final open = _openSelfClosing(targetTuv);
        return [
          TextNode(source.substring(tu.outerStart, targetTuv.outerStart)),
          EncodedNode(
            raw: _outer(targetTuv),
            children: content,
            encode: (inner) => '$open<seg>$inner</seg></${targetTuv!.name}>',
          ),
          TextNode(source.substring(targetTuv.outerEnd, tu.outerEnd)),
        ];
      }
      final insertAt = targetTuv.contentEnd;
      final segIndent = _indentBefore(sourceTuv, sourceSeg);
      return [
        TextNode(source.substring(tu.outerStart, insertAt)),
        EncodedNode(
          raw: '',
          children: content,
          encode: (inner) => '$segIndent<seg>$inner</seg>',
        ),
        TextNode(source.substring(insertAt, tu.outerEnd)),
      ];
    }

    // No target <tuv> yet: append a new <tuv xml:lang="..."> after the last
    // <tuv>.
    final content = _segContent(sourceSeg, label: label);
    if (!hasSegment(content)) return whole;

    final lastTuv = tuvs.last;
    final tuvIndent = _indentBefore(tu, sourceTuv);
    final segIndent = _indentBefore(sourceTuv, sourceSeg);
    final segTrailing = sourceTuv.end != null && segIndent.isNotEmpty
        ? tuvIndent
        : '';
    final langAttr =
        sourceTuv.start.attribute('xml:lang') != null ||
            sourceTuv.start.attribute('lang') == null
        ? 'xml:lang'
        : 'lang';
    final escapedLang = escapeMarkupAttribute(targetLang, '"');

    return [
      TextNode(source.substring(tu.outerStart, lastTuv.outerEnd)),
      EncodedNode(
        raw: '',
        children: content,
        encode: (inner) =>
            '$tuvIndent<tuv $langAttr="$escapedLang">'
            '$segIndent<seg>$inner</seg>$segTrailing</tuv>',
      ),
      TextNode(source.substring(lastTuv.outerEnd, tu.outerEnd)),
    ];
  }

  String Function(String inner) _segWrapper(XmlElement seg) {
    if (seg.end == null) {
      final open = _openSelfClosing(seg);
      return (inner) => '$open$inner</${seg.name}>';
    }
    final open = seg.start.raw(source);
    final close = seg.end!.raw(source);
    return (inner) => '$open$inner$close';
  }

  String _openSelfClosing(XmlElement element) {
    final tag = element.start.raw(source);
    final slash = tag.lastIndexOf('/');
    return '${tag.substring(0, slash).trimRight()}>';
  }

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

  List<DocNode> _segContent(XmlElement seg, {String? label}) {
    final cdata = _cdataOnly(seg);
    if (cdata != null) {
      final raw = cdata.raw(source);
      final inner = protectInlines([
        InlineText(raw.substring(9, raw.length - 3)),
      ], LocalisationPatterns.text);
      return [
        TextNode(source.substring(seg.contentStart, cdata.start + 9)),
        ...inlineContent(
          builder,
          inner,
          escape: escapeCdata,
          label: label,
          accept: looksLikeNaturalLanguage,
        ),
        TextNode(source.substring(cdata.end - 3, seg.contentEnd)),
      ];
    }
    return inlineContent(
      builder,
      protectInlines(_inlines(seg), LocalisationPatterns.text),
      escape: escapeMarkupText,
      label: label,
      accept: looksLikeNaturalLanguage,
      repair: (fragment) => repairInlineTags(fragment, html: false),
    );
  }

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

  List<Inline> _inlines(XmlElement element) {
    final items = <Inline>[];
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
          if (child.localName == 'hi' &&
              child.end != null &&
              !_isEmpty(child)) {
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
            // <bpt>, <ept>, <ph>, <it>, <ut>, empty <hi/>: protected inline code.
            items.add(InlineCode.text(_outer(child)));
          }
      }
    }
    return items;
  }
}
