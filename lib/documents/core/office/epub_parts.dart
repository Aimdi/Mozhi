import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';

/// XHTML content documents of an e-book.
///
/// The inline content of block elements (paragraphs, headings, list items,
/// table cells, captions, the title, …) becomes segments: inline markup
/// (emphasis, links, spans) keeps its formatting through placeholders,
/// `br` is a line break, and images, inline code, math and SVG are kept as
/// they are. Scripts, styles and `pre` blocks are never translated; the
/// root element's language is set to the target.
final class XhtmlPartBuilder extends PartBuilder {
  XhtmlPartBuilder(super.document, super.table);

  static const _blocks = {
    'address', 'article', 'aside', 'blockquote', 'body', 'caption', //
    'center', 'col', 'colgroup', 'dd', 'details', 'dialog', 'dir', 'div',
    'dl', 'dt', 'fieldset', 'figcaption', 'figure', 'footer', 'form', 'h1',
    'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header', 'hgroup', 'hr', 'html',
    'legend', 'li', 'main', 'menu', 'nav', 'ol', 'optgroup', 'option', 'p',
    'pre', 'section', 'summary', 'table', 'tbody', 'td', 'tfoot', 'th',
    'thead', 'title', 'tr', 'ul',
  };

  /// Elements whose content is never translated and that separate runs.
  static const _separators = {'script', 'style', 'template', 'pre'};

  static const _wrappers = {
    'a', 'abbr', 'acronym', 'b', 'bdi', 'bdo', 'big', 'cite', 'del', //
    'dfn', 'em', 'font', 'i', 'ins', 'label', 'mark', 'q', 's', 'small',
    'span', 'strike', 'strong', 'sub', 'sup', 'time', 'data', 'u',
  };

  final Map<SourceElement, bool> _blockish = {};

  bool _isXhtml(SourceElement element) => element.inNamespace(Ns.xhtml);

  /// Whether [element] is a block or holds one.
  bool _isBlockish(SourceElement element) => _blockish[element] ??=
      (_isXhtml(element) && _blocks.contains(element.localName)) ||
      element.elements.any(_isBlockish);

  bool _isSeparator(SourceElement element) =>
      _isXhtml(element) && _separators.contains(element.localName);

  @override
  bool isParagraph(SourceElement element) => false;

  @override
  List<PartNode>? paragraph(SourceElement element) => null;

  @override
  LanguageMarkKind? languageMark(SourceElement element) =>
      element.parent == null && element.isA(Ns.xhtml, 'html')
      ? LanguageMarkKind.htmlRoot
      : null;

  @override
  bool skip(SourceElement element) =>
      _isSeparator(element) || !_isBlockish(element);

  @override
  List<PartNode>? childrenOf(SourceElement element) {
    List<PartNode>? out;
    var position = element.startTagEnd;
    final run = <SourceNode>[];

    void emit(int start, List<PartNode> nodes, int end) {
      out ??= [];
      if (start > position) {
        out!.add(RawXml(source.substring(position, start)));
      }
      out!.addAll(nodes);
      position = end;
    }

    void flush() {
      if (run.isEmpty) return;
      final nodes = _run(run, element.prefix);
      if (nodes != null) emit(run.first.start, nodes, run.last.end);
      run.clear();
    }

    for (final child in element.children) {
      if (child is SourceElement &&
          (_isSeparator(child) || _isBlockish(child))) {
        flush();
        final nodes = node(child);
        if (nodes != null) emit(child.start, nodes, child.end);
      } else {
        run.add(child);
      }
    }
    flush();
    final result = out;
    if (result == null) return null;
    if (element.endTagStart > position) {
      result.add(RawXml(source.substring(position, element.endTagStart)));
    }
    return result;
  }

  /// The slot of a run of inline content.
  List<PartNode>? _run(List<SourceNode> nodes, String? prefix) {
    final atoms = <Atom>[];
    _inline(nodes, const [], atoms);
    final range = source.substring(nodes.first.start, nodes.last.end);
    final slot = buildSlot(
      atoms: atoms,
      table: table,
      open: () => const [],
      close: () => const [],
      original: () => [RawXml(range)],
      writer: XhtmlRunWriter(prefix),
    );
    return slot == null ? null : [slot];
  }

  void _inline(List<SourceNode> nodes, List<Wrapper> chain, List<Atom> atoms) {
    final context = RunContext(chain, RunStyle.none);
    for (final node in nodes) {
      switch (node) {
        case SourceText(:final value):
          atoms.add(
            TextAtom(
              value.replaceAll(_whitespace, ' '),
              context,
              collapsible: true,
            ),
          );
        case SourceMisc():
          break;
        case SourceElement():
          final local = _isXhtml(node) ? node.localName : null;
          if (local == 'br') {
            atoms.add(TextAtom('\n', context, neutral: true));
          } else if (local != null &&
              _wrappers.contains(local) &&
              !node.isSelfClosing) {
            final wrapper = Wrapper(
              source.substring(node.start, node.startTagEnd),
              source.substring(node.endTagStart, node.end),
            );
            _inline(node.children, [...chain, wrapper], atoms);
          } else {
            final kept = sourceOf(node);
            atoms.add(ObjectAtom(chain, () => [RawXml(kept)]));
          }
      }
    }
  }

  static final _whitespace = RegExp(r'[ \t\r\n\f]+');
}

/// Writes XHTML text: escaped characters and `br` for line breaks.
final class XhtmlRunWriter extends RunWriter {
  const XhtmlRunWriter(this.prefix);

  final String? prefix;

  @override
  void writeText(
    StringBuffer out,
    String text,
    RunStyle style,
    WriterState state,
    PartRenderer renderer,
  ) {
    final br = prefix == null ? '<br/>' : '<$prefix:br/>';
    out.write(text.split('\n').map(escapeXmlText).join(br));
  }
}

/// Writes plain element text.
final class PlainTextWriter extends RunWriter {
  const PlainTextWriter();

  @override
  void writeText(
    StringBuffer out,
    String text,
    RunStyle style,
    WriterState state,
    PartRenderer renderer,
  ) => out.write(escapeXmlText(text));
}

/// Elements holding plain text only ([paragraphs]); [firstLanguage]
/// optionally marks the first language element (`dc:language` in an
/// e-book's package document).
final class PlainTextPartBuilder extends PartBuilder {
  PlainTextPartBuilder(
    super.document,
    super.table, {
    required this.paragraphs,
    this.languages,
    this.languageKind = LanguageMarkKind.elementTag,
  });

  /// Whether an element is a paragraph.
  final bool Function(SourceElement element) paragraphs;

  /// Whether an element records the document language.
  final bool Function(SourceElement element)? languages;

  /// How the language is written.
  final LanguageMarkKind languageKind;
  bool _languageMarked = false;

  @override
  bool isParagraph(SourceElement element) => paragraphs(element);

  @override
  LanguageMarkKind? languageMark(SourceElement element) {
    final languages = this.languages;
    if (languages == null || _languageMarked || !languages(element)) {
      return null;
    }
    _languageMarked = true;
    return languageKind;
  }

  @override
  List<PartNode>? paragraph(SourceElement element) {
    if (element.elements.isNotEmpty) return plain(element);
    final text = element.text.replaceAll(RegExp(r'\s+'), ' ');
    return slotOrPlain(element, [
      TextAtom(text, RunContext.plain),
    ], writer: const PlainTextWriter());
  }
}
