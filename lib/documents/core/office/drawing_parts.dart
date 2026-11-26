import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';

/// DrawingML text (`a:p` paragraphs with `a:r` runs): slides and notes in
/// presentations, chart and axis titles, SmartArt and text boxes in any
/// Office document, and the alternative text and titles of pictures and
/// shapes (`p:cNvPr`, `xdr:cNvPr`, ...). With [translate] false, only
/// language marks are rewritten (`presentation.xml`, notes masters).
///
/// With [masters] (slide masters and layouts) only the text of shapes
/// that are not placeholders is translated: logos, footers and captions
/// drawn on the master appear on every slide. Placeholders on masters and
/// layouts hold prompts ("Click to edit Master title style", or a custom
/// prompt), which PowerPoint shows only while a slide's placeholder is
/// empty in the editor (never in a slide show or print, and in its own
/// language for the built-in prompts), so they are kept.
///
/// Runs with other formatting (including hyperlinks, which DrawingML keeps
/// in the run properties) keep it through placeholders; fields such as
/// slide numbers and dates and embedded math are kept as they are. Inline
/// chart text (`<c:tx><c:v>`, `<c:strLit>`, and `<c:strCache>` not backed
/// by a workbook cell formula `<c:f>`) is translated, while formula-linked
/// chart caches stay in sync with their cells.
final class DrawingPartBuilder extends PartBuilder {
  new(
    super.document,
    super.table, {
    this.translate = true,
    this.masters = false,
  });

  final bool translate;
  final bool masters;

  static const _shapes = {'sp', 'pic', 'graphicFrame', 'cxnSp', 'grpSp'};

  /// Whether [element] is inside a placeholder shape of a presentation.
  static bool _inPlaceholder(SourceElement element) {
    for (SourceElement? e = element; e != null; e = e.parent) {
      if (e.inNamespace(Ns.presentation) && _shapes.contains(e.localName)) {
        final properties = e.elements.firstOrNull;
        return properties
                ?.child(Ns.presentation, 'nvPr')
                ?.child(Ns.presentation, 'ph') !=
            null;
      }
    }
    return false;
  }

  bool _translates(SourceElement element) =>
      translate && (!masters || !_inPlaceholder(element));

  @override
  bool translatesAltText(SourceElement element) => _translates(element);

  /// Attributes that do not split runs.
  static const _ignored = {
    'lang',
    'altLang',
    'dirty',
    'err',
    'noProof',
    'smtClean',
    'smtId',
    'bmk',
  };

  static const _runProperties = {'rPr', 'defRPr', 'endParaRPr'};

  @override
  bool isParagraph(SourceElement element) =>
      (element.isA(Ns.drawing, 'p') || _isInlineChartText(element)) &&
      _translates(element);

  /// Whether [element] holds inline/embedded chart text not backed by a
  /// workbook cell formula (`<c:f>` / `<cx:f>`):
  /// - literal `<c:tx><c:v>…</c:v></c:tx>`
  /// - `<c:strLit><c:pt><c:v>…</c:v></c:pt></c:strLit>`
  /// - `<c:strCache>` / `<c:multiLvlStrCache>` whose parent reference has no
  ///   `<c:f>` formula
  /// - `<cx:strDim>` `<cx:pt>` when `<cx:strDim>` has no `<cx:f>` formula
  static bool _isInlineChartText(SourceElement element) {
    if (element.elements.isNotEmpty || element.isSelfClosing) return false;
    if (element.isA(Ns.chart, 'v')) {
      final parent = element.parent;
      if (parent == null) return false;
      if (parent.isA(Ns.chart, 'tx')) return true;
      if (!parent.isA(Ns.chart, 'pt')) return false;
      final container = parent.parent;
      if (container == null) return false;
      if (container.isA(Ns.chart, 'strLit')) return true;
      if (container.isA(Ns.chart, 'strCache')) {
        final ref = container.parent;
        return ref == null || !_hasChartFormula(ref, Ns.chart);
      }
      if (container.isA(Ns.chart, 'lvl')) {
        final cache = container.parent;
        if (cache != null && cache.isA(Ns.chart, 'multiLvlStrCache')) {
          final ref = cache.parent;
          return ref == null || !_hasChartFormula(ref, Ns.chart);
        }
      }
      return false;
    }
    if (element.isA(Ns.chartEx, 'pt')) {
      final lvl = element.parent;
      final dim = lvl?.parent;
      if (lvl != null &&
          lvl.isA(Ns.chartEx, 'lvl') &&
          dim != null &&
          dim.isA(Ns.chartEx, 'strDim')) {
        return !_hasChartFormula(dim, Ns.chartEx);
      }
    }
    return false;
  }

  static bool _hasChartFormula(SourceElement element, Set<String> ns) {
    final formula = element.child(ns, 'f');
    return formula != null && formula.text.trim().isNotEmpty;
  }

  @override
  LanguageMarkKind? languageMark(SourceElement element) =>
      element.inNamespace(Ns.drawing) &&
          _runProperties.contains(element.localName) &&
          element.attribute('lang') != null
      ? LanguageMarkKind.drawingRun
      : null;

  @override
  List<PartNode>? paragraph(SourceElement element) {
    if (_isInlineChartText(element)) {
      return slotOrPlain(element, [
        TextAtom(element.text.replaceAll('\r\n', '\n'), RunContext.plain),
      ], writer: const _ChartTextWriter());
    }
    final children = element.elements.toList();
    final properties =
        children.isNotEmpty && children.first.isA(Ns.drawing, 'pPr')
        ? children.first
        : null;
    final end =
        children.isNotEmpty && children.last.isA(Ns.drawing, 'endParaRPr')
        ? children.last
        : null;
    final atoms = <Atom>[];
    for (final child in children) {
      if (identical(child, properties) || identical(child, end)) continue;
      final local = child.inNamespace(Ns.drawing) ? child.localName : null;
      switch (local) {
        case 'r':
          final style = _style(child.child(Ns.drawing, 'rPr'));
          final text = child.child(Ns.drawing, 't');
          if (text != null) {
            atoms.add(TextAtom(text.text, RunContext(const [], style)));
          }
        case 'br':
          atoms.add(
            TextAtom(
              '\n',
              RunContext(const [], _style(child.child(Ns.drawing, 'rPr'))),
              neutral: true,
            ),
          );
        default:
          atoms.add(ObjectAtom(const [], () => whole(child)));
      }
    }
    return slotOrPlain(
      element,
      atoms,
      writer: DrawingRunWriter(element.prefix),
      open: () => [
        RawXml(source.substring(element.start, element.startTagEnd)),
        if (properties != null) ...whole(properties),
      ],
      close: () => [
        if (end != null) ...whole(end),
        RawXml(source.substring(element.endTagStart, element.end)),
      ],
    );
  }

  RunStyle _style(SourceElement? properties) => properties == null
      ? RunStyle.none
      : RunStyle(
          styleKey(properties, ignoredAttributes: _ignored),
          whole(properties),
        );
}

final class _ChartTextWriter extends RunWriter {
  const new();

  @override
  void writeText(
    StringBuffer out,
    String text,
    RunStyle style,
    WriterState state,
    PartRenderer renderer,
  ) => out.write(escapeXmlText(text));
}

/// Writes DrawingML runs: `a:r` with `a:t`, and `a:br` (with the run
/// properties) for line breaks.
final class DrawingRunWriter extends RunWriter {
  const new(this.prefix);

  final String? prefix;

  String _name(String local) => prefix == null ? local : '$prefix:$local';

  @override
  void writeText(
    StringBuffer out,
    String text,
    RunStyle style,
    WriterState state,
    PartRenderer renderer,
  ) {
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) {
        if (style.nodes.isEmpty) {
          out.write('<${_name('br')}/>');
        } else {
          out.write('<${_name('br')}>');
          renderer.writeStyle(out, style);
          out.write('</${_name('br')}>');
        }
      }
      final line = lines[i];
      if (line.isEmpty) continue;
      out.write('<${_name('r')}>');
      renderer.writeStyle(out, style);
      out.write(
        '<${_name('t')}>${escapeXmlText(line)}</${_name('t')}></${_name('r')}>',
      );
    }
  }
}
