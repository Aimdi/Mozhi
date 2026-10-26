import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';

/// WordprocessingML parts (`word/document.xml`, headers, footers,
/// footnotes, endnotes, comments; with [translate] false only their
/// language marks, for styles and settings).
///
/// Paragraphs (`w:p`) become segments. Runs with the same formatting are
/// merged; runs with other formatting, hyperlinks, tracked insertions and
/// content controls keep their formatting through placeholders; tabs,
/// footnote references, drawings (whose text boxes are translated as
/// paragraphs of their own), fields' instructions, deleted text, bookmarks
/// and comment ranges are kept as they are. Spelling marks are dropped
/// from translated paragraphs.
final class WordPartBuilder extends PartBuilder {
  new(super.document, super.table, {this.translate = true});

  final bool translate;

  /// Open complex fields per story (body, header, text box, …): true while
  /// in a field's instruction, false in its result.
  final Map<SourceElement?, List<bool>> _fields = {};

  static const _wrappers = {
    'hyperlink',
    'smartTag',
    'customXml',
    'ins',
    'moveTo',
    'fldSimple',
    'bdo',
    'dir',
  };

  static const _wrapperProperties = {'smartTagPr', 'customXmlPr', 'fldData'};

  /// Zero-width marks whose order matters.
  static final _rangeMark = RegExp(r'(RangeStart|RangeEnd|Start|End)$');

  static const _stories = {
    'body',
    'hdr',
    'ftr',
    'footnote',
    'endnote',
    'comment',
    'txbxContent',
    'docPartBody',
  };

  /// Formatting that does not split runs.
  static const _ignoredStyle = {'lang', 'noProof', 'rsid'};

  @override
  bool isParagraph(SourceElement element) =>
      translate && element.isA(Ns.word, 'p');

  @override
  LanguageMarkKind? languageMark(SourceElement element) =>
      element.inNamespace(Ns.word) &&
          (element.localName == 'lang' || element.localName == 'themeFontLang')
      ? LanguageMarkKind.wordLang
      : null;

  @override
  List<PartNode>? paragraph(SourceElement element) {
    final properties = element.elements.firstOrNull;
    final hasProperties = properties != null && properties.isA(Ns.word, 'pPr');
    final atoms = <Atom>[];
    final fields = _fields.putIfAbsent(_story(element), () => []);
    _inline(
      [
        for (final child in element.elements)
          if (!hasProperties || !identical(child, properties)) child,
      ],
      const [],
      atoms,
      fields,
    );
    return slotOrPlain(
      element,
      atoms,
      writer: WordRunWriter(element.prefix),
      open: () => [
        RawXml(source.substring(element.start, element.startTagEnd)),
        if (hasProperties) ...whole(properties),
      ],
    );
  }

  SourceElement? _story(SourceElement element) {
    for (var e = element.parent; e != null; e = e.parent) {
      if (e.inNamespace(Ns.word) && _stories.contains(e.localName)) return e;
    }
    return null;
  }

  void _inline(
    List<SourceElement> elements,
    List<Wrapper> chain,
    List<Atom> atoms,
    List<bool> fields,
  ) {
    for (final element in elements) {
      if (!element.inNamespace(Ns.word)) {
        atoms.add(_object(chain, element));
        continue;
      }
      final local = element.localName;
      if (local == 'r') {
        _run(element, chain, atoms, fields);
      } else if (local == 'proofErr') {
        // Spelling marks are stale once translated.
      } else if (_wrappers.contains(local) && _content(element).isNotEmpty) {
        final content = _content(element);
        final wrapper = Wrapper(
          source.substring(element.start, content.first.start),
          source.substring(element.endTagStart, element.end),
        );
        // Text between the properties and the content (whitespace) is
        // part of the opening.
        _inline(content, [...chain, wrapper], atoms, fields);
      } else if (_sdtContent(element) case final content?) {
        final wrapper = Wrapper(
          source.substring(element.start, content.startTagEnd),
          source.substring(content.endTagStart, element.end),
        );
        _inline(content.elements.toList(), [...chain, wrapper], atoms, fields);
      } else {
        atoms.add(_object(chain, element, ordered: _rangeMark.hasMatch(local)));
      }
    }
  }

  /// The children of a wrapper without its properties.
  static List<SourceElement> _content(SourceElement element) => [
    for (final child in element.elements)
      if (!(child.inNamespace(Ns.word) &&
          _wrapperProperties.contains(child.localName)))
        child,
  ];

  /// The content of an inline content control.
  static SourceElement? _sdtContent(SourceElement element) {
    if (element.localName != 'sdt') return null;
    final content = element.child(Ns.word, 'sdtContent');
    return content == null || content.isSelfClosing ? null : content;
  }

  void _run(
    SourceElement run,
    List<Wrapper> chain,
    List<Atom> atoms,
    List<bool> fields,
  ) {
    final first = run.elements.firstOrNull;
    final properties = first != null && first.isA(Ns.word, 'rPr')
        ? first
        : null;
    final style = properties == null
        ? RunStyle.none
        : RunStyle(
            styleKey(
              properties,
              ignoredChildren: _ignoredStyle,
              ignoredAttributes: _ignoredStyle,
            ),
            whole(properties),
          );
    final context = RunContext(chain, style);
    for (final child in run.elements) {
      if (identical(child, properties)) continue;
      final local = child.inNamespace(Ns.word) ? child.localName : null;
      if (local == 'fldChar') {
        switch (child.attribute('fldCharType', Ns.word)) {
          case 'begin':
            fields.add(true);
          case 'separate':
            if (fields.isNotEmpty) fields[fields.length - 1] = false;
          case 'end':
            if (fields.isNotEmpty) fields.removeLast();
        }
        atoms.add(_runObject(chain, run, properties, child, ordered: true));
        continue;
      }
      if (fields.contains(true)) {
        // A field's instruction (and fields nested in it) stays as it is.
        atoms.add(_runObject(chain, run, properties, child));
        continue;
      }
      switch (local) {
        case 't':
          atoms.add(TextAtom(child.text, context));
        case 'br'
            when switch (child.attribute('type', Ns.word)) {
              null || 'textWrapping' => true,
              _ => false,
            }:
          atoms.add(TextAtom('\n', context, neutral: true));
        case 'cr':
          atoms.add(TextAtom('\n', context, neutral: true));
        case 'noBreakHyphen':
          atoms.add(TextAtom('‑', context));
        case 'softHyphen':
          atoms.add(TextAtom('­', context));
        case 'lastRenderedPageBreak':
          // A layout hint Word writes again.
          break;
        default:
          atoms.add(_runObject(chain, run, properties, child));
      }
    }
  }

  ObjectAtom _object(
    List<Wrapper> chain,
    SourceElement element, {
    bool ordered = false,
  }) => ObjectAtom(chain, () => whole(element), ordered: ordered);

  /// [child] of [run] kept in a run of its own, with the run's formatting.
  ObjectAtom _runObject(
    List<Wrapper> chain,
    SourceElement run,
    SourceElement? properties,
    SourceElement child, {
    bool ordered = false,
  }) => ObjectAtom(chain, () {
    return [
      RawXml(source.substring(run.start, run.startTagEnd)),
      if (properties != null) ...whole(properties),
      ...whole(child),
      RawXml(source.substring(run.endTagStart, run.end)),
    ];
  }, ordered: ordered);
}

/// Writes WordprocessingML runs: `w:t` with preserved spaces, `w:br` for
/// line breaks, `w:tab`, and the special hyphens.
final class WordRunWriter extends RunWriter {
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
    out.write('<${_name('r')}>');
    renderer.writeStyle(out, style);
    var start = 0;
    void flush(int end) {
      if (end <= start) return;
      out.write(
        '<${_name('t')} xml:space="preserve">'
        '${escapeXmlText(text.substring(start, end))}</${_name('t')}>',
      );
    }

    for (var i = 0; i < text.length; i++) {
      final element = switch (text.codeUnitAt(i)) {
        0x0A => 'br',
        0x09 => 'tab',
        0x2011 => 'noBreakHyphen',
        0x00AD => 'softHyphen',
        _ => null,
      };
      if (element == null) continue;
      flush(i);
      out.write('<${_name(element)}/>');
      start = i + 1;
    }
    flush(text.length);
    out.write('</${_name('r')}>');
  }
}
