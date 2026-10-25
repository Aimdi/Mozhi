import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';

/// OpenDocument parts: `content.xml` (text documents, slides, spreadsheet
/// cells), the headers and footers in `styles.xml` ([translate] false for
/// presentations' master pages, whose text is placeholder prompts) and
/// language marks (`style:text-properties`, `dc:language` in `meta.xml`).
///
/// Paragraphs and headings (`text:p`, `text:h`) become segments; spans and
/// links keep their formatting through placeholders; `text:s`,
/// `text:line-break` and white space follow ODF's white space rules; tabs,
/// notes (whose paragraphs are translated on their own), frames, fields,
/// bookmarks and annotations are kept. Cells holding numbers, dates or
/// formulas are not translated.
final class OdfPartBuilder extends PartBuilder {
  OdfPartBuilder(
    super.document,
    super.table, {
    this.translate = true,
    this.mastersOnly = false,
  });

  final bool translate;

  /// Only paragraphs inside `office:master-styles` (styles.xml headers and
  /// footers).
  final bool mastersOnly;

  static const _wrappers = {'span', 'a', 'meta', 'meta-field'};

  /// Zero-width marks whose order matters.
  static final _rangeMark = RegExp(r'-(start|end)$');

  @override
  bool isParagraph(SourceElement element) =>
      translate &&
      element.inNamespace(Ns.odfText) &&
      (element.localName == 'p' || element.localName == 'h') &&
      (!mastersOnly || _inMasterStyles(element));

  @override
  LanguageMarkKind? languageMark(SourceElement element) {
    if (element.isA(Ns.odfStyle, 'text-properties')) {
      return LanguageMarkKind.odfTextProperties;
    }
    if (element.isA(Ns.dublinCore, 'language')) {
      return LanguageMarkKind.elementCulture;
    }
    return null;
  }

  static bool _inMasterStyles(SourceElement element) {
    for (var e = element.parent; e != null; e = e.parent) {
      if (e.isA(Ns.odfOffice, 'master-styles')) return true;
    }
    return false;
  }

  /// Whether [element] is in a spreadsheet cell that holds a number, date,
  /// formula or other non-text value.
  static bool _inValueCell(SourceElement element) {
    for (var e = element.parent; e != null; e = e.parent) {
      if (e.inNamespace(Ns.odfTable) &&
          (e.localName == 'table-cell' ||
              e.localName == 'covered-table-cell')) {
        if (e.attribute('formula', Ns.odfTable) != null) return true;
        final type =
            e.attribute('value-type', Ns.odfOffice) ??
            e.attribute('value-type', Ns.calcExt);
        return type != null && type != 'string';
      }
    }
    return false;
  }

  @override
  List<PartNode>? paragraph(SourceElement element) {
    if (_inValueCell(element)) {
      final kept = plain(element);
      return kept == null ? null : [UntranslatedScope(kept)];
    }
    final atoms = <Atom>[];
    _inline(element, const [], atoms);
    return slotOrPlain(element, atoms, writer: OdfRunWriter(element.prefix));
  }

  void _inline(SourceElement parent, List<Wrapper> chain, List<Atom> atoms) {
    final context = RunContext(chain, RunStyle.none);
    for (final node in parent.children) {
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
          _element(node, chain, context, atoms);
      }
    }
  }

  void _element(
    SourceElement element,
    List<Wrapper> chain,
    RunContext context,
    List<Atom> atoms,
  ) {
    final local = element.inNamespace(Ns.odfText) ? element.localName : null;
    switch (local) {
      case final name? when _wrappers.contains(name) && !element.isSelfClosing:
        final wrapper = Wrapper(
          source.substring(element.start, element.startTagEnd),
          source.substring(element.endTagStart, element.end),
        );
        _inline(element, [...chain, wrapper], atoms);
      case 's':
        final count = int.tryParse(element.attribute('c', Ns.odfText) ?? '');
        atoms.add(TextAtom(' ' * (count ?? 1).clamp(1, 1000), context));
      case 'line-break':
        atoms.add(TextAtom('\n', context, neutral: true));
      case 'soft-page-break':
        // A layout hint the office application writes again.
        break;
      default:
        final ordered =
            local != null && _rangeMark.hasMatch(local) ||
            element.isA(Ns.odfOffice, 'annotation-end');
        atoms.add(ObjectAtom(chain, () => whole(element), ordered: ordered));
    }
  }

  static final _whitespace = RegExp(r'[ \t\r\n]+');
}

/// Writes ODF text: escaped characters, `text:s` for spaces that would be
/// collapsed (repeated or at the start of a line) and `text:line-break`.
final class OdfRunWriter extends RunWriter {
  const OdfRunWriter(this.prefix);

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
    var spaces = 0;
    void flushSpaces() {
      if (spaces == 0) return;
      out.write(
        spaces == 1
            ? '<${_name('s')}/>'
            : '<${_name('s')} ${_name('c')}="$spaces"/>',
      );
      spaces = 0;
    }

    final plain = StringBuffer();
    void flushText() {
      if (plain.isEmpty) return;
      out.write(escapeXmlText(plain.toString()));
      plain.clear();
    }

    for (final rune in text.runes) {
      if (rune == 0x20) {
        if (state.atLineStart || state.afterSpace) {
          flushText();
          spaces++;
        } else {
          plain.write(' ');
        }
        state.afterSpace = true;
        continue;
      }
      flushSpaces();
      if (rune == 0x0A) {
        flushText();
        out.write('<${_name('line-break')}/>');
        state
          ..atLineStart = true
          ..afterSpace = false;
        continue;
      }
      if (rune == 0x09) {
        flushText();
        out.write('<${_name('tab')}/>');
      } else {
        plain.writeCharCode(rune);
      }
      state
        ..atLineStart = false
        ..afterSpace = false;
    }
    flushText();
    flushSpaces();
  }
}
