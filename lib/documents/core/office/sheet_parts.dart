import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';

/// SpreadsheetML strings: the shared strings table (`si`, each translated
/// once however many cells use it) and inline strings in worksheets
/// (`is`). Plain and rich text (`r` runs with their own `rPr`) are
/// supported; phonetic readings (`rPh`) are dropped from translated
/// strings. Numbers, dates, formulas and their cached results are never
/// strings here, so they stay untouched.
final class SheetPartBuilder extends PartBuilder {
  new(super.document, super.table);

  @override
  bool isParagraph(SourceElement element) =>
      element.inNamespace(Ns.sheet) &&
      (element.localName == 'si' || element.localName == 'is');

  @override
  bool skip(SourceElement element) =>
      // Formulas, values and the rest of a worksheet's cells.
      element.inNamespace(Ns.sheet) &&
      (element.localName == 'f' || element.localName == 'v');

  @override
  List<PartNode>? paragraph(SourceElement element) {
    final atoms = <Atom>[];
    final rich = element.child(Ns.sheet, 'r') != null;
    SourceElement? phonetic;
    for (final child in element.elements) {
      if (!child.inNamespace(Ns.sheet)) continue;
      switch (child.localName) {
        case 't' when !rich:
          atoms.add(TextAtom(decodeXstring(child.text), RunContext.plain));
        case 'r':
          final properties = child.child(Ns.sheet, 'rPr');
          final text = child.child(Ns.sheet, 't');
          if (text == null) continue;
          final style = properties == null
              ? RunStyle.none
              : RunStyle(styleKey(properties), whole(properties));
          atoms.add(
            TextAtom(decodeXstring(text.text), RunContext(const [], style)),
          );
        case 'phoneticPr':
          phonetic = child;
      }
    }
    final keptPhonetic = phonetic;
    return slotOrPlain(
      element,
      atoms,
      writer: SheetRunWriter(element.prefix, rich: rich),
      close: () => [
        if (keptPhonetic != null) ...whole(keptPhonetic),
        RawXml(source.substring(element.endTagStart, element.end)),
      ],
    );
  }
}

/// Writes SpreadsheetML string content: one `t` for plain strings, `r`
/// runs for rich text.
final class SheetRunWriter extends RunWriter {
  const new(this.prefix, {required this.rich});

  final String? prefix;
  final bool rich;

  String _name(String local) => prefix == null ? local : '$prefix:$local';

  @override
  void writeText(
    StringBuffer out,
    String text,
    RunStyle style,
    WriterState state,
    PartRenderer renderer,
  ) {
    final t =
        '<${_name('t')} xml:space="preserve">'
        '${escapeXmlText(encodeXstring(text))}</${_name('t')}>';
    if (!rich) {
      out.write(t);
      return;
    }
    out.write('<${_name('r')}>');
    renderer.writeStyle(out, style);
    out
      ..write(t)
      ..write('</${_name('r')}>');
  }
}

final _escape = RegExp('_x([0-9A-Fa-f]{4})_');

/// Decodes the `_xHHHH_` escapes of Office strings (`ST_Xstring`).
String decodeXstring(String text) => text.contains('_x')
    ? text.replaceAllMapped(
        _escape,
        (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
      )
    : text;

/// Encodes text for `ST_Xstring`: control characters other than tab and
/// line feed become `_xHHHH_`, and a literal `_xHHHH_` gets its underscore
/// escaped.
String encodeXstring(String text) {
  final escaped = text.replaceAllMapped(
    _escape,
    (match) => '_x005F_${match[0]!.substring(1)}',
  );
  final buffer = StringBuffer();
  for (final unit in escaped.codeUnits) {
    if (unit < 0x20 && unit != 0x09 && unit != 0x0A) {
      buffer.write(
        '_x${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}_',
      );
    } else {
      buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}
