import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';

/// DrawingML text (`a:p` paragraphs with `a:r` runs): slides and notes in
/// presentations, chart titles, SmartArt and text boxes in any Office
/// document. With [translate] false, only language marks are rewritten
/// (slide masters, `presentation.xml`).
///
/// Runs with other formatting (including hyperlinks, which DrawingML keeps
/// in the run properties) keep it through placeholders; fields such as
/// slide numbers and dates and embedded math are kept as they are.
final class DrawingPartBuilder extends PartBuilder {
  DrawingPartBuilder(super.document, super.table, {this.translate = true});

  final bool translate;

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
      translate && element.isA(Ns.drawing, 'p');

  @override
  LanguageMarkKind? languageMark(SourceElement element) =>
      element.inNamespace(Ns.drawing) &&
          _runProperties.contains(element.localName) &&
          element.attribute('lang') != null
      ? LanguageMarkKind.drawingRun
      : null;

  @override
  List<PartNode>? paragraph(SourceElement element) {
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

/// Writes DrawingML runs: `a:r` with `a:t`, and `a:br` (with the run
/// properties) for line breaks.
final class DrawingRunWriter extends RunWriter {
  const DrawingRunWriter(this.prefix);

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
