/// Pure-Dart "reader mode" extraction: turns an HTML document into a title
/// and a flat list of [ReadableBlock]s (headings, paragraphs, list items,
/// quotes, code and image captions), dropping navigation, ads, scripts and
/// other page chrome.
library;

import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:mozhi/web_translate/core/html_tree.dart';

/// What a [ReadableBlock] represents.
enum ReadableBlockKind {
  heading1,
  heading2,
  heading3,
  heading4,
  heading5,
  heading6,
  paragraph,
  listItem,
  quote,
  code,
  image;

  /// The heading kind for `<h[level]>` (clamped to 1-6).
  static ReadableBlockKind heading(int level) =>
      ReadableBlockKind.values[level.clamp(1, 6) - 1];

  bool get isHeading => index <= heading6.index;

  /// 1-6 for headings, else null.
  int? get headingLevel => isHeading ? index + 1 : null;
}

/// One block of readable content.
class ReadableBlock extends Equatable {
  const ReadableBlock({
    required this.kind,
    required this.text,
    this.src,
    this.number,
    this.depth = 0,
  });

  final ReadableBlockKind kind;

  /// Whitespace-collapsed text (line breaks from `<br>` are kept as `\n`).
  /// Code keeps its original whitespace; images carry their alt text.
  final String text;

  /// Absolute http(s) URL of an image block.
  final String? src;

  /// Ordinal of an item of an ordered list.
  final int? number;

  /// Nesting level of a list item (0 = top level).
  final int depth;

  /// Whether the block should be sent to a translator (code is kept as is).
  bool get isTranslatable =>
      kind != ReadableBlockKind.code && text.trim().isNotEmpty;

  ReadableBlock copyWith({String? text}) => ReadableBlock(
    kind: kind,
    text: text ?? this.text,
    src: src,
    number: number,
    depth: depth,
  );

  @override
  List<Object?> get props => [kind, text, src, number, depth];

  @override
  String toString() => 'ReadableBlock(${kind.name}, $text)';
}

/// The readable content of a page.
class ReadablePage extends Equatable {
  const ReadablePage({
    required this.title,
    required this.blocks,
    this.siteName,
    this.language,
  });

  /// Article title (may be empty).
  final String title;
  final List<ReadableBlock> blocks;

  /// `og:site_name` / `application-name`, when declared.
  final String? siteName;

  /// `<html lang>` of the document, when declared.
  final String? language;

  bool get isEmpty => blocks.isEmpty;

  /// Characters of text in [blocks].
  int get textLength =>
      blocks.fold(0, (length, block) => length + block.text.length);

  @override
  List<Object?> get props => [title, blocks, siteName, language];
}

/// Extracts the main readable content of HTML documents.
///
/// The main content is, in order of preference: the dominant `<article>`,
/// the element marked `itemprop="articleBody"`, `<main>` /
/// `role="main"`, else the container with the densest text (a
/// Readability-style score of paragraph length and commas propagated to
/// ancestors, penalised by link density) plus its related siblings.
///
/// Before that, `script`, `style`, `noscript`, `svg`, `nav`, `footer`,
/// `aside`, `form`, `header` (outside articles), hidden elements, ARIA
/// navigation landmarks and elements whose class/id look like ads, share
/// bars, comments, sidebars and the like are removed. When this leaves
/// almost nothing the page is extracted again without the class/id rules.
class ReadableExtractor {
  const ReadableExtractor({
    this.minArticleLength = 200,
    this.retryThreshold = 250,
  });

  /// Characters a semantic container (`article`, `main`) needs to be
  /// trusted as the main content (unless the whole page is shorter).
  final int minArticleLength;

  /// Below this many characters, the page is extracted again without the
  /// class/id heuristics (they sometimes hit the content itself).
  final int retryThreshold;

  /// Extracts [html]; relative image URLs are resolved against [baseUri]
  /// (and the document's `<base href>`).
  ReadablePage extract(String html, {Uri? baseUri}) {
    final strict = _extract(html, baseUri, strict: true);
    if (strict.textLength >= retryThreshold) return strict;
    final lenient = _extract(html, baseUri, strict: false);
    return lenient.textLength > strict.textLength ? lenient : strict;
  }

  /// Splits plain [text] into paragraphs (separated by blank lines).
  static ReadablePage fromPlainText(String text, {String title = ''}) {
    final blocks = <ReadableBlock>[
      for (final part in text.replaceAll('\r\n', '\n').split(_blankLines))
        if (_normalise(part.replaceAll('\n', '\u0000')).isNotEmpty)
          ReadableBlock(
            kind: ReadableBlockKind.paragraph,
            text: _normalise(part.replaceAll('\n', '\u0000')),
          ),
    ];
    return ReadablePage(title: title, blocks: blocks);
  }

  ReadablePage _extract(String html, Uri? baseUri, {required bool strict}) {
    final document = parseHtml(html);
    final meta = _Metadata.of(document);
    final base = _resolveBase(baseUri, meta.baseHref);
    final body = document.find('body') ?? document;

    _prune(body, strict: strict, inArticle: false, protected: false);
    final metrics = _Metrics();
    final roots = _contentRoots(body, metrics);

    final builder = _BlockBuilder(base);
    roots.forEach(builder.visitRoot);
    final blocks = builder.finish();
    final title = _pickTitle(meta, blocks);
    return ReadablePage(
      title: title,
      blocks: blocks,
      siteName: meta.siteName,
      language: meta.language,
    );
  }

  // -------------------------------------------------------------------
  // Pruning
  // -------------------------------------------------------------------

  static void _prune(
    HtmlElement element, {
    required bool strict,
    required bool inArticle,
    required bool protected,
  }) {
    for (final child in element.elementChildren.toList()) {
      if (_shouldDrop(
        child,
        strict: strict,
        inArticle: inArticle,
        protected: protected,
      )) {
        child.remove();
        continue;
      }
      _prune(
        child,
        strict: strict,
        inArticle: inArticle || child.name == 'article',
        protected: protected || _protectedTags.contains(child.name),
      );
    }
  }

  static bool _shouldDrop(
    HtmlElement element, {
    required bool strict,
    required bool inArticle,
    required bool protected,
  }) {
    final name = element.name;
    if (_droppedTags.contains(name)) return true;
    if (name == 'header' && !inArticle) return true;
    final attributes = element.attributes;
    if (attributes.containsKey('hidden')) return true;
    if (attributes['aria-hidden']?.trim().toLowerCase() == 'true') return true;
    final style = attributes['style'];
    if (style != null && _hiddenStyle.hasMatch(style)) return true;
    final role = attributes['role']?.trim().toLowerCase();
    if (role != null && _droppedRoles.contains(role)) return true;

    if (!strict || protected || _neverUnlikely.contains(name)) return false;
    if (name == 'header' && inArticle) return false;
    final classAndId = '${attributes['class'] ?? ''} ${attributes['id'] ?? ''}'
        .toLowerCase()
        .trim();
    if (classAndId.isEmpty) return false;
    for (final token in classAndId.split(_whitespace)) {
      if (_adToken.hasMatch(token)) return true;
    }
    return _unlikely.hasMatch(classAndId) &&
        !_maybeCandidate.hasMatch(classAndId);
  }

  // -------------------------------------------------------------------
  // Main content
  // -------------------------------------------------------------------

  List<HtmlElement> _contentRoots(HtmlElement body, _Metrics metrics) {
    final bodyLength = metrics.text(body);
    if (bodyLength == 0) return [body];
    final threshold = math.min(minArticleLength, bodyLength);

    bool dominant(HtmlElement? element) =>
        element != null &&
        metrics.text(element) >= threshold &&
        metrics.text(element) >= bodyLength * 0.25;

    HtmlElement? longest(Iterable<HtmlElement> elements) {
      HtmlElement? best;
      for (final element in elements) {
        if (best == null || metrics.text(element) > metrics.text(best)) {
          best = element;
        }
      }
      return best;
    }

    final articles = body.findAll('article').toList();
    final article = longest(articles);
    if (article != null && dominant(article)) {
      final total = articles.fold(0, (sum, e) => sum + metrics.text(e));
      // Many similar articles (a blog index): not one main article.
      final nested = articles
          .where((e) => e != article)
          .every((e) => e.hasAncestor((a) => a == article));
      if (nested || metrics.text(article) >= total * 0.5) return [article];
    }

    final articleBody = longest(
      body.descendants.where(
        (e) => (e.attributes['itemprop'] ?? '').toLowerCase().contains(
          'articlebody',
        ),
      ),
    );
    if (dominant(articleBody)) return [articleBody!];

    final main = longest(
      body.descendants.where(
        (e) =>
            e.name == 'main' ||
            e.attributes['role']?.trim().toLowerCase() == 'main',
      ),
    );
    if (dominant(main)) return [main!];

    final top = _densest(body, metrics);
    if (top == null) return [body];
    return _withSiblings(top, body, metrics);
  }

  static HtmlElement? _densest(HtmlElement body, _Metrics metrics) {
    for (final element in body.descendants) {
      if (!_isScorable(element)) continue;
      final length = metrics.text(element);
      if (length < 25) continue;
      final text = element.textContent;
      final commas = _commas.allMatches(text).length;
      final score = 1 + commas + math.min(length ~/ 100, 3);

      var ancestor = element.parent;
      for (var level = 0; level < 5 && ancestor != null; level++) {
        if (ancestor.name == '#document') break;
        final divider = switch (level) {
          0 => 1,
          1 => 2,
          _ => level * 3,
        };
        metrics.addScore(ancestor, score / divider);
        if (ancestor == body) break;
        ancestor = ancestor.parent;
      }
    }

    HtmlElement? top;
    var topScore = 0.0;
    for (final candidate in metrics.candidates) {
      final score = metrics.finalScore(candidate);
      if (top == null || score > topScore) {
        top = candidate;
        topScore = score;
      }
    }
    if (top == null) return null;
    // A lone child carries no more information than its parent.
    while (top!.parent != null &&
        top.parent != body &&
        top.parent!.name != '#document' &&
        top.parent!.elementChildren.length == 1) {
      top = top.parent;
    }
    return top;
  }

  static List<HtmlElement> _withSiblings(
    HtmlElement top,
    HtmlElement body,
    _Metrics metrics,
  ) {
    final parent = top.parent;
    if (top == body || parent == null || parent.name == '#document') {
      return [top];
    }
    final topScore = metrics.finalScore(top);
    final threshold = math.max(10, topScore * 0.2);
    final topClass = top.attributes['class'];
    return [
      for (final sibling in parent.elementChildren)
        if (sibling == top ||
            _isRelatedSibling(
              sibling,
              metrics,
              threshold: threshold,
              bonus:
                  topClass != null &&
                      topClass.isNotEmpty &&
                      sibling.attributes['class'] == topClass
                  ? topScore * 0.2
                  : 0,
            ))
          sibling,
    ];
  }

  static bool _isRelatedSibling(
    HtmlElement sibling,
    _Metrics metrics, {
    required num threshold,
    required num bonus,
  }) {
    if (metrics.hasScore(sibling) &&
        metrics.finalScore(sibling) + bonus >= threshold) {
      return true;
    }
    if (sibling.name != 'p') return false;
    final length = metrics.text(sibling);
    final density = metrics.linkDensity(sibling);
    if (length > 80) return density < 0.25;
    if (length == 0 || density > 0) return false;
    return RegExp(r'\.( |$)').hasMatch(sibling.textContent.trim());
  }

  static bool _isScorable(HtmlElement element) {
    final name = element.name;
    if (_scoredTags.contains(name)) return true;
    if (name != 'div' && name != 'section') return false;
    return !element.elementChildren.any((e) => _blockTags.contains(e.name));
  }

  // -------------------------------------------------------------------
  // Title
  // -------------------------------------------------------------------

  static String _pickTitle(_Metadata meta, List<ReadableBlock> blocks) {
    final declared = meta.ogTitle ?? meta.title;
    final title = declared == null
        ? ''
        : _stripSiteName(declared, meta.siteName);
    final h1 = blocks.indexWhere((b) => b.kind == ReadableBlockKind.heading1);
    if (h1 >= 0 && h1 <= 3) {
      final heading = blocks[h1].text;
      final a = _comparable(title);
      final b = _comparable(heading);
      if (a.isEmpty || a.contains(b) || b.contains(a)) {
        blocks.removeAt(h1);
        return heading;
      }
    }
    if (blocks.isNotEmpty &&
        blocks.first.kind.isHeading &&
        _comparable(blocks.first.text) == _comparable(title)) {
      blocks.removeAt(0);
    }
    if (title.isNotEmpty) return title;
    final heading = blocks.indexWhere((b) => b.kind.isHeading);
    if (heading >= 0 && heading <= 3) return blocks.removeAt(heading).text;
    return '';
  }

  static String _stripSiteName(String title, String? siteName) {
    final site = siteName == null ? '' : _comparable(siteName);
    for (final separator in _titleSeparators) {
      final last = title.lastIndexOf(separator);
      if (last <= 0) continue;
      final before = title.substring(0, last).trim();
      final after = title.substring(last + separator.length).trim();
      if (site.isNotEmpty && _comparable(after) == site) return before;
      final first = title.indexOf(separator);
      if (site.isNotEmpty && _comparable(title.substring(0, first)) == site) {
        return title.substring(first + separator.length).trim();
      }
      if (_wordCount(after) <= 4 && _wordCount(before) >= 3) return before;
    }
    return title;
  }

  static int _wordCount(String text) =>
      text.trim().isEmpty ? 0 : text.trim().split(_whitespace).length;

  static String _comparable(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), ' ')
      .trim();

  static Uri? _resolveBase(Uri? baseUri, String? baseHref) {
    if (baseHref == null || baseHref.trim().isEmpty) return baseUri;
    final href = Uri.tryParse(baseHref.trim());
    if (href == null) return baseUri;
    return baseUri == null ? href : baseUri.resolveUri(href);
  }
}

// ---------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------

class _Metadata {
  _Metadata({
    this.title,
    this.ogTitle,
    this.siteName,
    this.language,
    this.baseHref,
  });

  factory _Metadata.of(HtmlElement document) {
    String? title;
    String? ogTitle;
    String? twitterTitle;
    String? siteName;
    String? applicationName;
    String? baseHref;
    final html = document.find('html');
    for (final element in document.descendants) {
      switch (element.name) {
        case 'title':
          if (title == null &&
              !element.hasAncestor(
                (e) => e.name == 'svg' || e.name == 'math',
              )) {
            final text = _normalise(element.textContent);
            if (text.isNotEmpty) title = text;
          }
        case 'meta':
          final key =
              (element.attributes['property'] ?? element.attributes['name'])
                  ?.trim()
                  .toLowerCase();
          final content = _normalise(element.attributes['content'] ?? '');
          if (key == null || content.isEmpty) continue;
          switch (key) {
            case 'og:title':
              ogTitle ??= content;
            case 'twitter:title':
              twitterTitle ??= content;
            case 'og:site_name':
              siteName ??= content;
            case 'application-name':
              applicationName ??= content;
          }
        case 'base':
          baseHref ??= element.attributes['href'];
      }
    }
    final language = html?.attributes['lang']?.trim();
    return _Metadata(
      title: title,
      ogTitle: ogTitle ?? twitterTitle,
      siteName: siteName ?? applicationName,
      language: language == null || language.isEmpty ? null : language,
      baseHref: baseHref,
    );
  }

  final String? title;
  final String? ogTitle;
  final String? siteName;
  final String? language;
  final String? baseHref;
}

// ---------------------------------------------------------------------
// Text metrics and scores
// ---------------------------------------------------------------------

class _Metrics {
  final _text = <HtmlElement, int>{};
  final _links = <HtmlElement, int>{};
  final _scores = <HtmlElement, double>{};

  /// Collapsed text length of [element]'s subtree.
  int text(HtmlElement element) {
    _measure(element);
    return _text[element]!;
  }

  /// Share of [element]'s text that is inside links (0-1).
  double linkDensity(HtmlElement element) {
    final total = text(element);
    return total == 0 ? 0 : _links[element]! / total;
  }

  void _measure(HtmlElement element) {
    if (_text.containsKey(element)) return;
    var total = 0;
    var links = 0;
    for (final child in element.children) {
      switch (child) {
        case HtmlTextNode(:final text):
          final length = _collapsedLength(text);
          total += length;
          if (element.name == 'a') links += length;
        case final HtmlElement child:
          _measure(child);
          total += _text[child]!;
          links += child.name == 'a' ? _text[child]! : _links[child]!;
      }
    }
    _text[element] = total;
    _links[element] = math.min(total, links);
  }

  Iterable<HtmlElement> get candidates => _scores.keys;

  bool hasScore(HtmlElement element) => _scores.containsKey(element);

  void addScore(HtmlElement element, double score) {
    _scores[element] = (_scores[element] ?? _initialScore(element)) + score;
  }

  double finalScore(HtmlElement element) =>
      (_scores[element] ?? 0) * (1 - linkDensity(element));

  static double _initialScore(HtmlElement element) {
    final base = switch (element.name) {
      'div' => 5,
      'pre' || 'td' || 'blockquote' => 3,
      'address' || 'ol' || 'ul' || 'dl' || 'dd' || 'dt' || 'li' || 'form' => -3,
      'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' || 'th' => -5,
      _ => 0,
    };
    return (base + _classWeight(element)).toDouble();
  }

  static int _classWeight(HtmlElement element) {
    var weight = 0;
    for (final value in [
      element.attributes['class'],
      element.attributes['id'],
    ]) {
      if (value == null || value.isEmpty) continue;
      final lower = value.toLowerCase();
      if (_negative.hasMatch(lower)) weight -= 25;
      if (_positive.hasMatch(lower)) weight += 25;
    }
    return weight;
  }

  static int _collapsedLength(String text) {
    var length = 0;
    var space = true;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      final isSpace =
          c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0xA0;
      if (isSpace) {
        if (!space) length++;
        space = true;
      } else {
        length++;
        space = false;
      }
    }
    return space && length > 0 ? length - 1 : length;
  }
}

// ---------------------------------------------------------------------
// Block building
// ---------------------------------------------------------------------

/// The block a run of inline text belongs to.
class _Context {
  _Context(this.kind, {this.number, this.depth = 0});

  final ReadableBlockKind kind;

  /// Ordinal for the first block of an ordered list item.
  int? number;
  final int depth;
}

class _BlockBuilder {
  _BlockBuilder(this.baseUri);

  final Uri? baseUri;
  final List<ReadableBlock> _blocks = [];
  final StringBuffer _text = StringBuffer();
  int _linkChars = 0;
  int _inLink = 0;
  _Context _context = _Context(ReadableBlockKind.paragraph);

  void visitRoot(HtmlElement root) {
    _context = _Context(ReadableBlockKind.paragraph);
    _visitElement(root, _context);
    _flush();
  }

  List<ReadableBlock> finish() {
    _flush();
    final result = <ReadableBlock>[];
    for (final block in _blocks) {
      if (result.isNotEmpty && result.last == block) continue;
      result.add(block);
    }
    return result;
  }

  void _visit(HtmlNode node, _Context context) {
    switch (node) {
      case HtmlTextNode(:final text):
        _append(text);
      case final HtmlElement element:
        _visitElement(element, context);
    }
  }

  void _visitChildren(HtmlElement element, _Context context) {
    for (final child in element.children) {
      _visit(child, context);
    }
  }

  void _visitElement(HtmlElement element, _Context context) {
    final name = element.name;
    final level = _headingLevel(name);
    if (level != null) {
      _block(element, _Context(ReadableBlockKind.heading(level)));
      return;
    }
    switch (name) {
      case 'br':
        _text.write('\n');
      case 'hr':
        _flush();
      case 'img':
        _image(element);
      case 'pre':
        _flush();
        _code(element);
      case 'ul' || 'ol' || 'menu':
        _list(element, context);
      case 'li':
        _block(
          element,
          _Context(ReadableBlockKind.listItem, depth: context.depth),
        );
      case 'blockquote':
        _block(element, _Context(ReadableBlockKind.quote));
      case 'tr' when _isSimpleRow(element):
        _flush();
        var first = true;
        for (final cell in element.elementChildren) {
          if (cell.name != 'td' && cell.name != 'th') continue;
          if (!first) _text.write(' | ');
          first = false;
          _visitChildren(cell, context);
        }
        _flush();
      case 'a':
        _inLink++;
        _visitChildren(element, context);
        _inLink--;
      default:
        if (_blockTags.contains(name) || name == '#document') {
          _block(element, context);
        } else {
          _visitChildren(element, context);
        }
    }
  }

  void _block(HtmlElement element, _Context context) {
    _flush();
    final saved = _context;
    _context = context;
    _visitChildren(element, context);
    _flush();
    _context = saved;
  }

  void _list(HtmlElement list, _Context context) {
    _flush();
    final ordered = list.name == 'ol';
    var counter = int.tryParse(list.attributes['start']?.trim() ?? '') ?? 1;
    final depth = context.kind == ReadableBlockKind.listItem
        ? context.depth + 1
        : 0;
    final saved = _context;
    _context = _Context(ReadableBlockKind.listItem, depth: depth);
    for (final child in list.children) {
      if (child is HtmlElement && child.name == 'li') {
        final value = int.tryParse(child.attributes['value']?.trim() ?? '');
        if (value != null) counter = value;
        _block(
          child,
          _Context(
            ReadableBlockKind.listItem,
            number: ordered ? counter : null,
            depth: depth,
          ),
        );
        counter++;
      } else {
        _visit(child, _context);
      }
    }
    _flush();
    _context = saved;
  }

  void _image(HtmlElement image) {
    final attributes = image.attributes;
    final width = int.tryParse(attributes['width']?.trim() ?? '');
    final height = int.tryParse(attributes['height']?.trim() ?? '');
    if ((width != null && width <= 1) || (height != null && height <= 1)) {
      return; // Tracking pixel.
    }
    final alt = _normalise(attributes['alt'] ?? '');
    if (alt.isEmpty) return;
    final small =
        (width != null && width <= 48) || (height != null && height <= 48);
    final emoji = (attributes['class'] ?? '').contains('emoji');
    if (small || emoji || alt.runes.length <= 2) {
      _append(alt);
      return;
    }
    _flush();
    _blocks.add(
      ReadableBlock(
        kind: ReadableBlockKind.image,
        text: alt,
        src: _imageSource(attributes),
      ),
    );
  }

  String? _imageSource(Map<String, String> attributes) {
    for (final key in const [
      'src',
      'data-src',
      'data-lazy-src',
      'data-original',
    ]) {
      final value = attributes[key]?.trim();
      if (value == null || value.isEmpty || value.startsWith('data:')) {
        continue;
      }
      final uri = Uri.tryParse(value);
      if (uri == null) continue;
      final resolved = baseUri?.resolveUri(uri) ?? uri;
      if (resolved.isScheme('http') || resolved.isScheme('https')) {
        return resolved.toString();
      }
    }
    return null;
  }

  void _code(HtmlElement pre) {
    final buffer = StringBuffer();
    void collect(HtmlElement element) {
      for (final child in element.children) {
        switch (child) {
          case HtmlTextNode(:final text):
            buffer.write(text);
          case HtmlElement(name: 'br'):
            buffer.write('\n');
          case final HtmlElement element:
            collect(element);
        }
      }
    }

    collect(pre);
    final text = buffer
        .toString()
        .replaceAll('\r\n', '\n')
        .replaceFirst(RegExp(r'^\n+'), '')
        .trimRight();
    if (text.trim().isEmpty) return;
    _blocks.add(ReadableBlock(kind: ReadableBlockKind.code, text: text));
  }

  void _append(String text) {
    if (text.isEmpty) return;
    final collapsed = text.replaceAll(_whitespace, ' ').replaceAll('​', '');
    if (collapsed.isEmpty) return;
    if (_inLink > 0) _linkChars += collapsed.trim().length;
    _text.write(collapsed);
  }

  void _flush() {
    if (_text.isEmpty) return;
    final raw = _text.toString();
    final links = _linkChars;
    _text.clear();
    _linkChars = 0;
    final text = _normalise(raw);
    if (text.isEmpty) return;
    final context = _context;
    final kind = context.kind;
    if ((kind == ReadableBlockKind.paragraph ||
            kind == ReadableBlockKind.listItem) &&
        text.length < 100 &&
        links >= text.length * 0.9) {
      return; // Navigation-like leftovers ("Related: <a>...</a>").
    }
    _blocks.add(
      ReadableBlock(
        kind: kind,
        text: text,
        number: context.number,
        depth: kind == ReadableBlockKind.listItem ? context.depth : 0,
      ),
    );
    context.number = null;
  }

  static bool _isSimpleRow(HtmlElement row) => row.elementChildren
      .where((cell) => cell.name == 'td' || cell.name == 'th')
      .every(
        (cell) =>
            !cell.descendants.any((e) => _rowBreakingTags.contains(e.name)),
      );

  static int? _headingLevel(String name) {
    if (name.length != 2 || name.codeUnitAt(0) != 0x68) return null; // h
    final level = name.codeUnitAt(1) - 0x30;
    return level >= 1 && level <= 6 ? level : null;
  }
}

/// Collapses whitespace (keeping explicit `\n` line breaks, written as
/// `\n` or NUL) and trims.
String _normalise(String text) => text
    .replaceAll(RegExp('[ \t\r\f  - 　]+'), ' ')
    .replaceAll('\u0000', '\n')
    .replaceAll(RegExp(r' *\n *'), '\n')
    .replaceAll(RegExp(r'\n{2,}'), '\n')
    .replaceAll('​', '')
    .trim();

final _whitespace = RegExp(r'\s+');
final _blankLines = RegExp(r'\n[ \t]*\n');
final _commas = RegExp('[,،﹐，、]');
final _hiddenStyle = RegExp(
  r'display\s*:\s*none|visibility\s*:\s*hidden',
  caseSensitive: false,
);

/// Readability's "unlikely candidate" class/id patterns.
final _unlikely = RegExp(
  '-ad-|ai2html|banner|breadcrumbs|combx|comment|community|cover-wrap|disqus|'
  'extra|footer|gdpr|header|legends|menu|related|remark|replies|rss|shoutbox|'
  'sidebar|skyscraper|social|sponsor|supplemental|ad-break|agegate|pagination|'
  'pager|popup|yom-remote|newsletter|cookie|consent|subscribe|share|'
  'masthead|toolbar|navbar|topbar|byline-share|promo',
);
final _maybeCandidate = RegExp(
  'and|article|body|column|content|main|mathjax|shadow',
);

/// Class/id tokens that always mark ads, share bars and the like.
final _adToken = RegExp(
  r'^(ads?|adv|advert\w*|adsbygoogle|ad[-_]\w+|\w+[-_]ads?|sponsored|'
  r'promoted|paywall|sr-only|visually-hidden|screen-reader-text|'
  r'skip-link|cookie-banner|share-buttons|social-share)$',
);

final _positive = RegExp(
  'article|body|content|entry|hentry|h-entry|main|page|pagination|post|text|'
  'blog|story',
);
final _negative = RegExp(
  r'-1|hidden|^hid$| hid$| hid |^hid |banner|combx|comment|com-|contact|foot|'
  'footer|footnote|gdpr|masthead|media|meta|outbrain|promo|related|scroll|'
  'share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget',
);

const _titleSeparators = [' | ', ' – ', ' — ', ' - ', ' · ', ' :: ', ' » '];

/// Removed with their content.
const _droppedTags = {
  'script',
  'style',
  'noscript',
  'template',
  'svg',
  'math',
  'nav',
  'footer',
  'aside',
  'form',
  'iframe',
  'object',
  'embed',
  'canvas',
  'video',
  'audio',
  'button',
  'select',
  'textarea',
  'input',
  'dialog',
  'head',
  'link',
  'meta',
  'title',
  'map',
  'frameset',
  'frame',
  'applet',
};

const _droppedRoles = {
  'navigation',
  'banner',
  'contentinfo',
  'complementary',
  'search',
  'dialog',
  'alertdialog',
  'menu',
  'menubar',
  'toolbar',
};

/// Never removed by the class/id heuristics.
const _neverUnlikely = {'html', 'body', 'article', 'main', 'a'};

/// Content inside these is never removed by the class/id heuristics.
const _protectedTags = {'pre', 'code', 'table'};

/// Paragraph-like elements whose text is scored.
const _scoredTags = {'p', 'pre', 'td', 'blockquote'};

/// Elements that start a new block.
const _blockTags = {
  'address',
  'article',
  'aside',
  'blockquote',
  'body',
  'caption',
  'center',
  'dd',
  'details',
  'dialog',
  'div',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hgroup',
  'html',
  'legend',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'summary',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
};

/// Cell content that makes a table row a layout row (cells become blocks).
const _rowBreakingTags = {
  'p',
  'div',
  'ul',
  'ol',
  'table',
  'pre',
  'blockquote',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'section',
  'article',
};
