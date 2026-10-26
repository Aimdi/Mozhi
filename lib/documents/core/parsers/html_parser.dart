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
import 'package:mozhi/documents/core/parsers/xml_tree.dart'
    show checkDocumentLength;

/// Parses HTML and XHTML ([DocumentFormat.html]).
///
/// Translated: the visible text, one segment per block (paragraph,
/// heading, list item, table cell, ...), with inline elements (`<a>`,
/// `<b>`, `<em>`, `<span>`, `<br>`, `<img>`, ...) as placeholders inside
/// it, the page `<title>`, and the attributes people read: `alt`, `title`,
/// `placeholder`, `aria-label`, `aria-description`, the `value` of
/// `<input>` buttons and the `content` of `<meta>` descriptions.
///
/// Kept verbatim: markup and every other attribute, `<script>`, `<style>`,
/// `<template>`, `<pre>`, `<code>`, `<kbd>`, `<samp>`, `<var>`, `<svg>`,
/// `<math>`, `<textarea>`, comments (also conditional comments), and
/// whatever is marked `translate="no"` or `class="notranslate"`
/// (`translate="yes"` inside such an element is translated again).
/// Character references are kept, except where the translation replaces
/// the text; translations are escaped, so XHTML stays well-formed.
///
/// Once something is translated, `<html lang>` (and `xml:lang` in XHTML)
/// is set to [targetLanguage] (and `dir` for right-to-left languages), and
/// a declared legacy charset becomes UTF-8.
///
/// Throws [DocumentParseException] only for input that is too large;
/// malformed HTML is read the forgiving way browsers do.
ParsedDocument parseHtml(String text, {String? targetLanguage}) {
  checkDocumentLength(text, 'HTML');
  return _HtmlParser(text, canonicalLanguageTag(targetLanguage)).parse();
}

/// Elements that sit inside a line of text.
const _inline = {
  'a',
  'abbr',
  'acronym',
  'b',
  'bdi',
  'bdo',
  'big',
  'br',
  'cite',
  'code',
  'data',
  'del',
  'dfn',
  'em',
  'font',
  'i',
  'img',
  'input',
  'ins',
  'kbd',
  'label',
  'mark',
  'math',
  'nobr',
  'q',
  'rp',
  'rt',
  'ruby',
  's',
  'samp',
  'small',
  'span',
  'strike',
  'strong',
  'sub',
  'sup',
  'svg',
  'time',
  'tt',
  'u',
  'var',
  'wbr',
};

/// Elements whose content is never translated (kept whole).
const _verbatim = {
  'canvas',
  'code',
  'iframe',
  'kbd',
  'math',
  'noembed',
  'noframes',
  'object',
  'plaintext',
  'pre',
  'rp',
  'rt',
  'samp',
  'script',
  'style',
  'svg',
  'template',
  'textarea',
  'var',
  'xmp',
};

/// Verbatim elements that may stand at the edge of a sentence without
/// being part of it (icons, scripts).
const _movable = {'svg', 'math', 'script', 'style', 'template', 'br', 'wbr'};

/// Attributes translated on any element.
const _textAttributes = {
  'alt',
  'title',
  'placeholder',
  'aria-label',
  'aria-description',
};

/// `<meta name|property>` values whose `content` is translated.
const _metaText = {
  'description',
  'og:description',
  'og:title',
  'twitter:description',
  'twitter:title',
};

class _Open {
  const new(this.name, {required this.translatable, this.pair});

  final String name;
  final bool translatable;

  /// The pair number of an inline element's open code; null for blocks.
  final int? pair;
}

class _HtmlParser {
  new(this.source, this.target)
    : tokens = lexMarkup(source, html: true),
      xhtml = _isXhtml(source);

  final String source;
  final String? target;
  final List<MarkupToken> tokens;
  final bool xhtml;
  final DocumentBuilder builder = DocumentBuilder();

  /// The document up to the `<html>` start tag, and from there.
  final NodeList _before = NodeList();
  NodeList _out = NodeList();
  final List<_Open> _stack = [];
  final List<Inline> _run = [];
  int _pairs = 0;
  MarkupToken? _htmlTag;
  final Map<String, String> _replacements = {};

  static bool _isXhtml(String source) {
    final head = source.length > 2048 ? source.substring(0, 2048) : source;
    return head.trimLeft().replaceFirst('\uFEFF', '').startsWith('<?xml') ||
        head.contains('http://www.w3.org/1999/xhtml');
  }

  bool get _translatable => _stack.isEmpty || _stack.last.translatable;

  ParsedDocument parse() {
    var i = 0;
    while (i < tokens.length) {
      i = _token(i);
    }
    _flush();

    var nodes = <DocNode>[..._before.nodes, ..._htmlNodes()];
    if (_replacements.isNotEmpty && hasSegment(nodes)) {
      final children = nodes;
      nodes = [
        EncodedNode(
          raw: identityText(children),
          children: children,
          encode: (rendered) {
            var value = rendered;
            for (final MapEntry(key: old, value: fixed)
                in _replacements.entries) {
              value = value.replaceFirst(old, fixed);
            }
            return value;
          },
        ),
      ];
    }
    builder.add(nodes);
    return builder.build(DocumentFormat.html);
  }

  /// The nodes from `<html>` on, with its `lang` set once translated.
  List<DocNode> _htmlNodes() {
    final tag = _htmlTag;
    final language = target;
    if (tag == null || language == null) return _out.nodes;
    final values = <String, String>{'lang': language};
    if (xhtml || tag.attribute('xml:lang', ignoreCase: true) != null) {
      values['xml:lang'] = language;
    }
    final dir = tag.attribute('dir', ignoreCase: true);
    if (isRightToLeft(language)) {
      values['dir'] = 'rtl';
    } else if (dir != null &&
        asciiLower(dir.rawValue(source)).trim() == 'rtl') {
      values['dir'] = 'ltr';
    }
    return replacePrefixWhenTranslated(
      _out.nodes,
      tag.raw(source),
      setAttributes(source, tag, values),
    );
  }

  /// Handles the token at [i]; returns the index of the next one.
  int _token(int i) {
    final token = tokens[i];
    switch (token.kind) {
      case MarkupKind.text:
        if (_translatable) {
          _run.addAll(
            textInlines(
              source,
              token.start,
              token.end,
              html: true,
              collapse: true,
            ),
          );
        } else {
          _literal(token.raw(source));
        }
        return i + 1;
      case MarkupKind.processing:
        final raw = token.raw(source);
        if (raw.startsWith('<?xml')) {
          final fixed = utf8Declaration(raw);
          if (fixed != raw) _replacements[raw] = fixed;
        }
        return _neutral(i);
      case MarkupKind.comment ||
          MarkupKind.declaration ||
          MarkupKind.cdata ||
          MarkupKind.rawText:
        return _neutral(i);
      case MarkupKind.endTag:
        return _endTag(i);
      case MarkupKind.startTag:
        return _startTag(i);
    }
  }

  /// Comments and declarations: part of a sentence, but never translated.
  int _neutral(int i) {
    final raw = tokens[i].raw(source);
    if (_translatable) {
      _run.add(InlineCode.text(raw, movable: true));
    } else {
      _literal(raw);
    }
    return i + 1;
  }

  void _literal(String text) {
    _flush();
    _out.text(text);
  }

  void _flush() {
    if (_run.isEmpty) return;
    final label = _stack.lastWhere(
      (open) => open.pair == null,
      orElse: () => const _Open('body', translatable: true),
    );
    _out.addAll(
      inlineContent(
        builder,
        protectInlines(_run, LocalisationPatterns.html),
        escape: escapeMarkupText,
        label: label.name,
        repair: (fragment) => repairInlineTags(fragment, html: true),
      ),
    );
    _run.clear();
  }

  bool _elementTranslatable(MarkupToken token) {
    final translate = token.attribute('translate', ignoreCase: true);
    if (translate != null) {
      final value = asciiLower(translate.rawValue(source)).trim();
      if (value == 'no') return false;
      if (value == 'yes' || value.isEmpty) return true;
    }
    final classes = token.attribute('class', ignoreCase: true);
    if (classes != null &&
        classes
            .rawValue(source)
            .split(RegExp(r'\s+'))
            .contains('notranslate')) {
      return false;
    }
    return _translatable;
  }

  int _startTag(int i) {
    final token = tokens[i];
    final name = token.lowerName;
    if (name == 'html' && _htmlTag == null) {
      _flush();
      _before.addAll(_out.nodes);
      _out = NodeList();
      _htmlTag = token;
    }
    if (name == 'meta') _noteCharset(token);

    final translatable = _elementTranslatable(token);
    final inline = _inline.contains(name);
    final insideText = _translatable && inline;

    if (_verbatim.contains(name) || (!translatable && inline)) {
      final last = token.selfClosing ? i : _matchingEnd(i, name);
      final raw = source.substring(token.start, tokens[last].end);
      if (_translatable && (inline || _movable.contains(name))) {
        _run.add(InlineCode.text(raw, movable: _movable.contains(name)));
      } else {
        _literal(raw);
      }
      return last + 1;
    }

    if (name == 'title') {
      _flush();
      _out.text(token.raw(source));
      final next = i + 1 < tokens.length ? tokens[i + 1] : null;
      if (next != null && next.kind == MarkupKind.rawText) {
        if (translatable) {
          _out.addAll(
            inlineContent(
              builder,
              protectInlines(
                textInlines(
                  source,
                  next.start,
                  next.end,
                  html: true,
                  collapse: true,
                ),
                LocalisationPatterns.html,
              ),
              escape: escapeMarkupText,
              label: 'title',
            ),
          );
        } else {
          _out.text(next.raw(source));
        }
        return i + 2;
      }
      return i + 1;
    }

    final nodes = _tagNodes(token, translatable: translatable);
    final isVoid = htmlVoidElements.contains(name);
    if (insideText) {
      if (isVoid || token.selfClosing) {
        _run.add(
          InlineCode(nodes, movable: name == 'img' || _movable.contains(name)),
        );
      } else {
        final pair = _pairs++;
        _run.add(InlineCode(nodes, role: CodeRole.open, pair: pair));
        _stack.add(_Open(name, translatable: translatable, pair: pair));
      }
      return i + 1;
    }
    _flush();
    _out.addAll(nodes);
    if (!isVoid && !token.selfClosing) {
      _stack.add(_Open(name, translatable: translatable));
    }
    return i + 1;
  }

  int _endTag(int i) {
    final token = tokens[i];
    final name = token.lowerName;
    final raw = token.raw(source);
    final index = _stack.lastIndexWhere((open) => open.name == name);
    if (index < 0) {
      // A stray end tag.
      if (_translatable && _inline.contains(name)) {
        _run.add(InlineCode.text(raw));
      } else {
        _literal(raw);
      }
      return i + 1;
    }
    final open = _stack[index];
    final wasTranslatable = _translatable;
    _stack.removeRange(index, _stack.length);
    final pair = open.pair;
    if (pair != null && wasTranslatable) {
      _run.add(InlineCode.text(raw, role: CodeRole.close, pair: pair));
    } else {
      _literal(raw);
    }
    return i + 1;
  }

  /// Index of the token that ends the element starting at [i]: its end tag,
  /// or the last token before an end tag of an ancestor.
  int _matchingEnd(int i, String name) {
    var depth = 0;
    for (var j = i + 1; j < tokens.length; j++) {
      final token = tokens[j];
      if (token.kind == MarkupKind.startTag &&
          !token.selfClosing &&
          token.lowerName == name) {
        depth++;
      } else if (token.kind == MarkupKind.endTag) {
        final end = token.lowerName;
        if (end == name) {
          if (depth == 0) return j;
          depth--;
        } else if (_stack.any((open) => open.name == end)) {
          return j - 1;
        }
      }
    }
    return tokens.length - 1;
  }

  /// A start tag as nodes, with segments for its translatable attributes.
  List<DocNode> _tagNodes(MarkupToken token, {required bool translatable}) {
    final nodes = NodeList();
    var position = token.start;
    final name = token.lowerName;
    for (final attribute in token.attributes) {
      if (!attribute.hasValue ||
          !translatable ||
          !_translatedAttribute(token, attribute)) {
        continue;
      }
      final inlines = protectInlines(
        textInlines(
          source,
          attribute.valueStart,
          attribute.valueEnd,
          html: true,
          collapse: true,
        ),
        LocalisationPatterns.html,
      );
      final quote = attribute.quote;
      final content = inlineContent(
        builder,
        inlines,
        escape: (text) => escapeMarkupAttribute(text, quote),
        label: '$name@${asciiLower(attribute.name)}',
        accept: looksLikeNaturalLanguage,
        lineBreak: ' ',
      );
      nodes.text(source.substring(position, attribute.valueStart));
      if (quote.isEmpty && hasSegment(content)) {
        nodes.addAll([
          EncodedNode(
            raw: attribute.rawValue(source),
            children: content,
            encode: (value) => '"$value"',
          ),
        ]);
      } else {
        nodes.addAll(content);
      }
      position = attribute.valueEnd;
    }
    nodes.text(source.substring(position, token.end));
    return nodes.nodes;
  }

  bool _translatedAttribute(MarkupToken tag, MarkupAttribute attribute) {
    final name = asciiLower(attribute.name);
    if (_textAttributes.contains(name)) return true;
    final element = tag.lowerName;
    String? value(String attributeName) {
      final found = tag.attribute(attributeName, ignoreCase: true);
      return found == null ? null : asciiLower(found.rawValue(source)).trim();
    }

    if (element == 'meta' && name == 'content') {
      return _metaText.contains(value('name')) ||
          _metaText.contains(value('property'));
    }
    if (element == 'input' && name == 'value') {
      return const {'submit', 'button', 'reset'}.contains(value('type'));
    }
    return false;
  }

  /// Remembers a legacy charset declaration to switch to UTF-8.
  void _noteCharset(MarkupToken token) {
    final charset = token.attribute('charset', ignoreCase: true);
    if (charset != null) {
      if (!_isUnicode(charset.rawValue(source))) {
        _replacements[token.raw(source)] = setAttributes(source, token, {
          'charset': 'utf-8',
        });
      }
      return;
    }
    final equiv = token.attribute('http-equiv', ignoreCase: true);
    final content = token.attribute('content', ignoreCase: true);
    if (equiv == null ||
        content == null ||
        asciiLower(equiv.rawValue(source)).trim() != 'content-type') {
      return;
    }
    final value = content.rawValue(source);
    final match = RegExp(
      r'charset\s*=\s*([^\s;"]+)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null || _isUnicode(match.group(1)!)) return;
    _replacements[token.raw(source)] = setAttributes(source, token, {
      'content': value.replaceRange(match.start, match.end, 'charset=utf-8'),
    });
  }

  static bool _isUnicode(String charset) {
    final name = asciiLower(charset.trim());
    return name == 'utf-8' || name == 'utf8' || name.startsWith('utf-16');
  }
}
