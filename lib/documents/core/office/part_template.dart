import 'package:mozhi/documents/core/document_builder.dart' show containsLetter;
import 'package:mozhi/documents/core/office/language_tags.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:xml/xml_events.dart' show XmlAttributeType;

// -------------------------------------------------------------------------
// Template nodes
// -------------------------------------------------------------------------

/// A node of an XML part's template. Rendering every node without
/// translations gives the part's source text back exactly.
sealed class PartNode {
  const new();
}

/// XML copied as it is.
final class RawXml extends PartNode {
  const new(this.xml);

  final String xml;
}

/// Nodes inside a paragraph that is not translated: their language marks
/// keep the original language.
final class UntranslatedScope extends PartNode {
  const new(this.children);

  final List<PartNode> children;
}

/// How a [LanguageMark] records the language.
enum LanguageMarkKind {
  /// `w:lang` / `w:themeFontLang` (`w:val`, `w:eastAsia`, `w:bidi`).
  wordLang,

  /// DrawingML run properties (`lang`); spelling marks are dropped.
  drawingRun,

  /// ODF `style:text-properties` (`fo:language`, `style:language-asian`,
  /// `style:language-complex` and their countries and scripts).
  odfTextProperties,

  /// The XHTML root (`lang`, `xml:lang`).
  htmlRoot,

  /// An element whose text is the language (`dc:language`), written as a
  /// culture name (`de-DE`).
  elementCulture,

  /// An element whose text is the language, written as a BCP 47 tag (`de`).
  elementTag,
}

/// The start tag (or, for the element kinds, the whole element) of an
/// element that records a language: rewritten for the target language
/// when its scope is translated.
final class LanguageMark extends PartNode {
  const new({
    required this.kind,
    required this.source,
    required this.qualifiedName,
    required this.attributes,
    required this.selfClosing,
    this.endTag = '',
  });

  /// A mark for [element] in [document].
  factory of(
    LanguageMarkKind kind,
    SourceElement element,
    SourceDocument document,
  ) {
    final text =
        kind == LanguageMarkKind.elementCulture ||
        kind == LanguageMarkKind.elementTag;
    final source = document.source;
    return LanguageMark(
      kind: kind,
      source: text
          ? document.of(element)
          : source.substring(element.start, element.startTagEnd),
      qualifiedName: element.qualifiedName,
      attributes: element.attributes,
      selfClosing: element.isSelfClosing,
      endTag: text && !element.isSelfClosing
          ? source.substring(element.endTagStart, element.end)
          : '',
    );
  }

  final LanguageMarkKind kind;

  /// The original XML.
  final String source;
  final String qualifiedName;
  final List<SourceAttribute> attributes;
  final bool selfClosing;
  final String endTag;

  /// The XML for [tag].
  String rewrite(LanguageTag tag) {
    switch (kind) {
      case LanguageMarkKind.elementCulture || LanguageMarkKind.elementTag:
        final value = kind == LanguageMarkKind.elementTag
            ? tag.bcp47
            : tag.culture;
        final start = _startTag(attributes, selfClosing: false);
        return '$start${escapeXmlText(value)}'
            '${endTag.isEmpty ? '</$qualifiedName>' : endTag}';
      case LanguageMarkKind.wordLang:
        final name = switch (tag.scriptClass) {
          ScriptClass.western => 'val',
          ScriptClass.asian => 'eastAsia',
          ScriptClass.complex => 'bidi',
        };
        return _startTag([
          for (final attribute in attributes)
            if (attribute.localName == name &&
                Ns.word.contains(attribute.namespace))
              _with(attribute, tag.culture)
            else
              attribute,
        ], selfClosing: selfClosing);
      case LanguageMarkKind.drawingRun:
        return _startTag(
          [
            for (final attribute in attributes)
              if (attribute.namespace == null &&
                  (attribute.localName == 'err' ||
                      attribute.localName == 'dirty'))
                null
              else if (attribute.namespace == null &&
                  attribute.localName == 'lang')
                _with(attribute, tag.culture)
              else
                attribute,
          ].nonNulls.toList(),
          selfClosing: selfClosing,
        );
      case LanguageMarkKind.odfTextProperties:
        final (
          language,
          country,
          scriptName,
          namespaces,
        ) = switch (tag.scriptClass) {
          ScriptClass.western => ('language', 'country', 'script', Ns.odfFo),
          ScriptClass.asian => (
            'language-asian',
            'country-asian',
            'script-asian',
            Ns.odfStyle,
          ),
          ScriptClass.complex => (
            'language-complex',
            'country-complex',
            'script-complex',
            Ns.odfStyle,
          ),
        };
        final hasLanguage = attributes.any(
          (a) => a.localName == language && namespaces.contains(a.namespace),
        );
        if (!hasLanguage) return source;
        final region = tag.officeRegion;
        final script = tag.script;
        return _startTag([
          for (final attribute in attributes)
            if (!namespaces.contains(attribute.namespace))
              attribute
            else if (attribute.localName == language)
              _with(attribute, tag.language)
            else if (attribute.localName == country) ...[
              if (region != null) _with(attribute, region),
            ] else if (attribute.localName == scriptName) ...[
              if (script != null) _with(attribute, script),
            ] else
              attribute,
        ], selfClosing: selfClosing);
      case LanguageMarkKind.htmlRoot:
        final present = attributes.any(_isHtmlLang);
        return _startTag([
          for (final attribute in attributes)
            if (_isHtmlLang(attribute))
              _with(attribute, tag.bcp47)
            else
              attribute,
          if (!present) ...[
            SourceAttribute(
              qualifiedName: 'lang',
              localName: 'lang',
              namespace: null,
              value: tag.bcp47,
              quote: XmlAttributeType.DOUBLE_QUOTE,
            ),
            SourceAttribute(
              qualifiedName: 'xml:lang',
              localName: 'lang',
              namespace: Ns.xml,
              value: tag.bcp47,
              quote: XmlAttributeType.DOUBLE_QUOTE,
            ),
          ],
        ], selfClosing: selfClosing);
    }
  }

  static bool _isHtmlLang(SourceAttribute attribute) =>
      attribute.localName == 'lang' &&
      (attribute.namespace == null || attribute.namespace == Ns.xml);

  static SourceAttribute _with(SourceAttribute attribute, String value) =>
      SourceAttribute(
        qualifiedName: attribute.qualifiedName,
        localName: attribute.localName,
        namespace: attribute.namespace,
        value: value,
        quote: attribute.quote,
      );

  String _startTag(
    List<SourceAttribute> attributes, {
    required bool selfClosing,
  }) {
    final buffer = StringBuffer('<$qualifiedName');
    for (final attribute in attributes) {
      final quote = attribute.quote == XmlAttributeType.SINGLE_QUOTE
          ? "'"
          : '"';
      buffer.write(
        ' ${attribute.qualifiedName}=$quote'
        '${escapeXmlAttribute(attribute.value, attribute.quote)}$quote',
      );
    }
    buffer.write(selfClosing ? '/>' : '>');
    return buffer.toString();
  }
}

// -------------------------------------------------------------------------
// Paragraph slots
// -------------------------------------------------------------------------

/// An inline element around runs (a hyperlink, a span, a tracked
/// insertion): written around the text that keeps it. Compared by
/// identity.
final class Wrapper {
  new(this.open, this.close);

  final String open;
  final String close;
}

/// Run formatting (`w:rPr`, `a:rPr`): [key] compares formatting while
/// ignoring language and spelling marks; [nodes] write it.
final class RunStyle {
  const new(this.key, this.nodes);

  static const none = RunStyle('', []);

  final String key;
  final List<PartNode> nodes;
}

/// The formatting a piece of text is written with: the [chain] of
/// wrappers (outermost first) and the run [style].
final class RunContext {
  const new(this.chain, this.style);

  static const plain = RunContext([], RunStyle.none);

  final List<Wrapper> chain;
  final RunStyle style;

  bool sameAs(RunContext other) {
    if (style.key != other.style.key || chain.length != other.chain.length) {
      return false;
    }
    for (var i = 0; i < chain.length; i++) {
      if (!identical(chain[i], other.chain[i])) return false;
    }
    return true;
  }
}

/// A piece of a rendered paragraph.
sealed class OutItem {
  const new();

  List<Wrapper> get chain;
}

/// Text written with [context].
final class OutText extends OutItem {
  const new(this.context, this.text);

  final RunContext context;
  final String text;

  @override
  List<Wrapper> get chain => context.chain;
}

/// Content kept as it is (a tab, a footnote reference, an image, a field),
/// inside [chain].
final class OutObject extends OutItem {
  const new(this.chain, this.nodes);

  @override
  final List<Wrapper> chain;
  final List<PartNode> nodes;
}

/// What placeholder `⟨n⟩` of a paragraph stands for: kept [objects], then
/// a switch to the formatting [switchTo].
final class SlotPlaceholder {
  const new({
    required this.objects,
    required this.switchTo,
    required this.ordered,
    required this.glueBefore,
    required this.glueAfter,
  });

  final List<OutObject> objects;
  final RunContext? switchTo;

  /// Objects whose order matters (field characters, bookmark and comment
  /// ranges): such placeholders keep their original order, whatever order
  /// the translation puts them in.
  final bool ordered;

  /// Whether the placeholder touched non-space text before / after it in
  /// the original (spaces an engine adds there are removed).
  final bool glueBefore;
  final bool glueAfter;
}

/// Writes text runs of one format.
abstract class RunWriter {
  const new();

  /// Writes [text] (with `\n` line breaks) formatted with [style].
  void writeText(
    StringBuffer out,
    String text,
    RunStyle style,
    WriterState state,
    PartRenderer renderer,
  );
}

/// What a [RunWriter] remembers between the runs of one paragraph.
final class WriterState {
  /// Nothing has been written yet (or a line break was the last thing).
  bool atLineStart = true;

  /// The last character written was a space.
  bool afterSpace = false;
}

/// A translatable paragraph: renders [original] when untranslated, else
/// [open], the translation's runs and [close].
final class ParagraphSlot extends PartNode {
  const new({
    required this.segment,
    required this.original,
    required this.open,
    required this.close,
    required this.lead,
    required this.trail,
    required this.base,
    required this.placeholders,
    required this.writer,
  });

  final int segment;
  final List<PartNode> original;
  final List<PartNode> open;
  final List<PartNode> close;

  /// Whitespace and kept content before / after the text.
  final List<OutItem> lead;
  final List<OutItem> trail;

  /// The formatting of text outside formatting placeholders.
  final RunContext base;
  final List<SlotPlaceholder> placeholders;
  final RunWriter writer;
}

// -------------------------------------------------------------------------
// Building slots
// -------------------------------------------------------------------------

/// Assigns segment numbers; identical texts share one segment (translated
/// once).
final class SegmentTable {
  final Map<String, int> _index = {};
  final List<Segment> segments = [];
  Set<int> _current = {};

  /// Starts collecting the segments of a part; returns the set.
  Set<int> startPart() => _current = {};

  /// The number of the segment with [text].
  int add(String text) {
    final index = _index.putIfAbsent(text, () {
      segments.add(Segment(text));
      return segments.length - 1;
    });
    _current.add(index);
    return index;
  }
}

/// A piece of a paragraph's content, as a format parser reads it.
sealed class Atom {
  const new();
}

/// Text in [context]. [neutral] text (line breaks) never switches the
/// formatting; [collapsible] text had its whitespace collapsed (ODF,
/// XHTML), so a space right after another one is dropped.
final class TextAtom extends Atom {
  const new(
    this.text,
    this.context, {
    this.neutral = false,
    this.collapsible = false,
  });

  final String text;
  final RunContext context;
  final bool neutral;
  final bool collapsible;
}

/// Content kept as it is; [build] makes its template (called once, in
/// document order, after the paragraph's own segment is known).
final class ObjectAtom extends Atom {
  const new(this.chain, this.build, {this.ordered = false});

  final List<Wrapper> chain;
  final List<PartNode> Function() build;
  final bool ordered;
}

/// Builds the slot of a paragraph made of [atoms], or returns null when it
/// holds no letters (it is then left as it is).
ParagraphSlot? buildSlot({
  required List<Atom> atoms,
  required SegmentTable table,
  required List<PartNode> Function() open,
  required List<PartNode> Function() close,
  required List<PartNode> Function() original,
  required RunWriter writer,
}) {
  final items = _collapse(atoms);

  // The body runs from the first to the last text with non-space content.
  var first = -1;
  var last = -1;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is TextAtom && item.text.trim().isNotEmpty) {
      if (first < 0) first = i;
      last = i;
    }
  }
  if (first < 0) return null;

  final body = items.sublist(first, last + 1);
  final firstText = body.first as TextAtom;
  final leadSpace = _leadingSpace.stringMatch(firstText.text) ?? '';
  if (leadSpace.isNotEmpty) {
    body[0] = _withText(firstText, firstText.text.substring(leadSpace.length));
  }
  final lastText = body.last as TextAtom;
  final trailSpace = _trailingSpace.stringMatch(lastText.text) ?? '';
  if (trailSpace.isNotEmpty) {
    body[body.length - 1] = _withText(
      lastText,
      lastText.text.substring(0, lastText.text.length - trailSpace.length),
    );
  }

  final plain = StringBuffer();
  for (final item in body) {
    if (item is TextAtom) plain.write(item.text);
  }
  if (!containsLetter(plain.toString())) return null;

  // The formatting holding the most text is the base.
  final counts = <RunContext, int>{};
  var base = firstText.context;
  var best = -1;
  for (final item in body) {
    if (item is! TextAtom || item.neutral) continue;
    final known = counts.keys.where(item.context.sameAs).firstOrNull;
    final key = known ?? item.context;
    final count = (counts[key] ?? 0) + item.text.length;
    counts[key] = count;
    if (count > best) {
      best = count;
      base = key;
    }
  }

  // The segment text, with a placeholder for every formatting switch and
  // every group of kept objects.
  final text = StringBuffer();
  final pending = <_PendingPlaceholder>[];
  var objects = <ObjectAtom>[];
  var current = base;
  void flush(RunContext? switchTo) {
    if (objects.isEmpty && switchTo == null) return;
    final start = text.length;
    text.write(placeholder(pending.length + 1));
    pending.add(_PendingPlaceholder(objects, switchTo, start, text.length));
    objects = [];
  }

  for (var i = 0; i < body.length; i++) {
    final item = body[i];
    switch (item) {
      case TextAtom(:final neutral, :final context):
        // A line break goes with the formatting of the text after it.
        final target = neutral ? _nextContext(body, i) ?? current : context;
        if (!target.sameAs(current)) {
          flush(target);
          current = target;
        } else {
          flush(null);
        }
        text.write(item.text);
      case ObjectAtom():
        objects.add(item);
    }
  }
  flush(current.sameAs(base) ? null : base);

  final segmentText = text.toString().replaceAll('\r\n', '\n');
  final segment = table.add(segmentText);

  // Templates of kept content, in document order (nested paragraphs, such
  // as text boxes and notes, get their segments after this one).
  final openNodes = open();
  final lead = <OutItem>[
    for (final item in items.sublist(0, first)) _outItem(item),
    if (leadSpace.isNotEmpty) OutText(firstText.context, leadSpace),
  ];
  bool isSpace(int at) =>
      at < 0 || at >= segmentText.length || segmentText[at].trim().isEmpty;
  final placeholders = [
    for (final spec in pending)
      SlotPlaceholder(
        objects: [
          for (final object in spec.objects)
            OutObject(object.chain, object.build()),
        ],
        switchTo: spec.switchTo,
        ordered: spec.objects.any((object) => object.ordered),
        glueBefore: !isSpace(spec.start - 1),
        glueAfter: !isSpace(spec.end),
      ),
  ];
  final trail = <OutItem>[
    if (trailSpace.isNotEmpty) OutText(lastText.context, trailSpace),
    for (final item in items.sublist(last + 1)) _outItem(item),
  ];
  return ParagraphSlot(
    segment: segment,
    original: original(),
    open: openNodes,
    close: close(),
    lead: lead,
    trail: trail,
    base: base,
    placeholders: placeholders,
    writer: writer,
  );
}

/// The formatting of the first non-neutral text after `body[index]`.
RunContext? _nextContext(List<Atom> body, int index) {
  for (var i = index + 1; i < body.length; i++) {
    final item = body[i];
    if (item is TextAtom && !item.neutral) return item.context;
  }
  return null;
}

final _leadingSpace = RegExp(r'^\s+');
final _trailingSpace = RegExp(r'\s+$');

class _PendingPlaceholder {
  const new(this.objects, this.switchTo, this.start, this.end);

  final List<ObjectAtom> objects;
  final RunContext? switchTo;
  final int start;
  final int end;
}

OutItem _outItem(Atom atom) => switch (atom) {
  TextAtom(:final context, :final text) => OutText(context, text),
  ObjectAtom(:final chain, :final build) => OutObject(chain, build()),
};

TextAtom _withText(TextAtom atom, String text) => TextAtom(
  text,
  atom.context,
  neutral: atom.neutral,
  collapsible: atom.collapsible,
);

/// Drops a collapsible space that follows another space (or starts the
/// paragraph or a line).
List<Atom> _collapse(List<Atom> atoms) {
  var afterSpace = true;
  final result = <Atom>[];
  for (final atom in atoms) {
    switch (atom) {
      case TextAtom(:final collapsible, :final neutral):
        var text = atom.text;
        if (collapsible && afterSpace && text.startsWith(' ')) {
          text = text.substring(1);
        }
        if (text.isEmpty) continue;
        afterSpace = neutral || text.endsWith(' ');
        result.add(identical(text, atom.text) ? atom : _withText(atom, text));
      case ObjectAtom():
        afterSpace = false;
        result.add(atom);
    }
  }
  return result;
}

/// A canonical description of [element]'s formatting for comparing runs:
/// its children and attributes in order, without the attributes named in
/// [ignoredAttributes] and the children in [ignoredChildren] (local
/// names).
String styleKey(
  SourceElement? element, {
  Set<String> ignoredAttributes = const {},
  Set<String> ignoredChildren = const {},
}) {
  if (element == null) return '';
  final buffer = StringBuffer();
  void write(SourceElement e) {
    buffer
      ..write('<')
      ..write(e.namespace)
      ..write('|')
      ..write(e.localName);
    final attributes = [
      for (final attribute in e.attributes)
        if (!attribute.qualifiedName.startsWith('xmlns') &&
            !ignoredAttributes.contains(attribute.localName))
          '${attribute.namespace}|${attribute.localName}=${attribute.value}',
    ]..sort();
    for (final attribute in attributes) {
      buffer
        ..write(' ')
        ..write(attribute);
    }
    buffer.write('>');
    for (final node in e.children) {
      switch (node) {
        case SourceElement():
          if (!ignoredChildren.contains(node.localName)) write(node);
        case SourceText(:final value):
          buffer.write(value);
        case SourceMisc():
          break;
      }
    }
    buffer.write('</>');
  }

  write(element);
  // Run properties that hold nothing but ignored marks equal none at all.
  final key = buffer.toString();
  return key == '<${element.namespace}|${element.localName}></>' ? '' : key;
}

// -------------------------------------------------------------------------
// Rendering
// -------------------------------------------------------------------------

/// Renders templates with [translations] (indexed like [segments]; null,
/// blank or unchanged entries keep the original).
final class PartRenderer {
  new({
    required this.translations,
    required this.segments,
    required this.language,
  }) : documentTranslated = Iterable<int>.generate(segments.length)
           .any((index) => _changed(translations, segments, index));

  final List<String?> translations;
  final List<Segment> segments;

  /// The target language, written where the document records languages
  /// (null: languages stay as they are).
  final LanguageTag? language;

  /// Whether any segment is translated.
  final bool documentTranslated;

  /// The translation of segment [index], or null when it keeps the
  /// original.
  String? translationOf(int index) =>
      _changed(translations, segments, index) ? translations[index] : null;

  static bool _changed(
    List<String?> translations,
    List<Segment> segments,
    int index,
  ) {
    if (index >= translations.length) return false;
    final translation = translations[index];
    return translation != null &&
        translation.trim().isNotEmpty &&
        translation != segments[index].text;
  }

  /// Renders a whole part.
  String renderPart(List<PartNode> nodes) {
    final out = StringBuffer();
    write(out, nodes, translated: documentTranslated);
    return out.toString();
  }

  /// Writes [nodes]; language marks are rewritten when [translated].
  void write(
    StringBuffer out,
    List<PartNode> nodes, {
    required bool translated,
  }) {
    for (final node in nodes) {
      switch (node) {
        case RawXml(:final xml):
          out.write(xml);
        case UntranslatedScope(:final children):
          write(out, children, translated: false);
        case LanguageMark(:final source):
          final tag = language;
          out.write(translated && tag != null ? node.rewrite(tag) : source);
        case ParagraphSlot():
          _writeSlot(out, node);
      }
    }
  }

  void _writeSlot(StringBuffer out, ParagraphSlot slot) {
    final translation = translationOf(slot.segment);
    if (translation == null) {
      write(out, slot.original, translated: false);
      return;
    }
    write(out, slot.open, translated: true);
    _writeItems(out, [
      ...slot.lead,
      ..._translationItems(slot, translation),
      ...slot.trail,
    ], slot.writer);
    write(out, slot.close, translated: true);
  }

  /// The runs of [translation]: text between placeholders in the
  /// formatting the placeholders switch to, kept objects where the
  /// placeholders are (or at the end when the engine dropped them).
  List<OutItem> _translationItems(ParagraphSlot slot, String translation) {
    final text = translation.replaceAll('\r\n', '\n').trim();
    final placeholders = slot.placeholders;
    final matches = [
      for (final match in placeholderPattern.allMatches(text))
        if (int.parse(match.group(1)!) case final n
            when n >= 1 && n <= placeholders.length)
          (match, n)
        else
          (match, 0),
    ];

    // Ordered placeholders keep their original order.
    final seen = <int>{};
    final orderedPositions = <int>[];
    for (final (_, number) in matches) {
      if (number == 0 || !seen.add(number)) continue;
      if (placeholders[number - 1].ordered) orderedPositions.add(number);
    }
    final sorted = [...orderedPositions]..sort();
    final remap = {
      for (var i = 0; i < orderedPositions.length; i++)
        orderedPositions[i]: sorted[i],
    };

    final items = <OutItem>[];
    final used = <int>{};
    var context = slot.base;
    var last = 0;
    for (final (match, found) in matches) {
      var before = text.substring(last, match.start);
      last = match.end;
      final number = remap[found] ?? found;
      if (number == 0 || !used.add(number)) {
        // An unknown or repeated placeholder: dropped.
        items.add(OutText(context, before));
        continue;
      }
      final spec = placeholders[number - 1];
      if (spec.glueBefore) before = before.replaceFirst(_spacesAtEnd, '');
      items
        ..add(OutText(context, before))
        ..addAll(spec.objects);
      context = spec.switchTo ?? context;
      if (spec.glueAfter) {
        while (last < text.length &&
            (text[last] == ' ' || text[last] == '\t')) {
          last++;
        }
      }
    }
    items.add(OutText(context, text.substring(last)));
    // Never lose kept content (images, notes, fields) the engine dropped.
    for (var number = 1; number <= placeholders.length; number++) {
      if (!used.contains(number)) {
        items.addAll(placeholders[number - 1].objects);
      }
    }
    return items;
  }

  static final _spacesAtEnd = RegExp(r'[ \t]+$');

  void _writeItems(StringBuffer out, List<OutItem> items, RunWriter writer) {
    // Merge neighbouring text in the same formatting.
    final merged = <OutItem>[];
    for (final item in items) {
      if (item is OutText) {
        if (item.text.isEmpty) continue;
        final previous = merged.isEmpty ? null : merged.last;
        if (previous is OutText && previous.context.sameAs(item.context)) {
          merged[merged.length - 1] = OutText(
            previous.context,
            '${previous.text}${item.text}',
          );
          continue;
        }
      }
      merged.add(item);
    }

    final state = WriterState();
    var open = const <Wrapper>[];
    for (final item in merged) {
      final chain = item.chain;
      var common = 0;
      while (common < open.length &&
          common < chain.length &&
          identical(open[common], chain[common])) {
        common++;
      }
      for (var i = open.length - 1; i >= common; i--) {
        out.write(open[i].close);
      }
      for (var i = common; i < chain.length; i++) {
        out.write(chain[i].open);
      }
      open = chain;
      switch (item) {
        case OutText(:final text, :final context):
          writer.writeText(out, text, context.style, state, this);
        case OutObject(:final nodes):
          write(out, nodes, translated: true);
          state
            ..atLineStart = false
            ..afterSpace = false;
      }
    }
    for (var i = open.length - 1; i >= 0; i--) {
      out.write(open[i].close);
    }
  }

  /// Writes a run style (always in a translated paragraph).
  void writeStyle(StringBuffer out, RunStyle style) =>
      write(out, style.nodes, translated: true);
}

// -------------------------------------------------------------------------
// Walking a part
// -------------------------------------------------------------------------

/// Builds the template of one XML part: walks the elements, turning
/// paragraphs into slots and language marks into [LanguageMark]s; every
/// other subtree stays raw source text.
abstract class PartBuilder {
  new(this.document, this.table);

  final SourceDocument document;
  final SegmentTable table;

  String get source => document.source;

  /// Whether [element] is a paragraph of this format.
  bool isParagraph(SourceElement element) => false;

  /// The language mark kind of [element], if it records a language.
  LanguageMarkKind? languageMark(SourceElement element) => null;

  /// Whether [element] and everything in it is kept as it is.
  bool skip(SourceElement element) => false;

  /// The slot (or kept template) of paragraph [element].
  List<PartNode>? paragraph(SourceElement element) => plain(element);

  /// The template of the whole part.
  List<PartNode> build() {
    final root = document.root;
    final nodes = node(root);
    return [
      if (nodes == null)
        RawXml(source)
      else ...[
        RawXml(source.substring(0, root.start)),
        ...nodes,
        RawXml(source.substring(root.end)),
      ],
    ];
  }

  /// The template of [element], or null when it is kept as it is.
  List<PartNode>? node(SourceElement element) {
    if (skip(element)) return null;
    if (isParagraph(element)) return paragraph(element);
    return plain(element);
  }

  /// The template of [element] as a plain container (also for a paragraph
  /// that is not translated), or null when it is kept as it is.
  List<PartNode>? plain(SourceElement element) {
    final mark = languageMark(element);
    if (mark == LanguageMarkKind.elementCulture ||
        mark == LanguageMarkKind.elementTag) {
      return [LanguageMark.of(mark!, element, document)];
    }
    final inner = childrenOf(element);
    if (mark == null && inner == null) return null;
    return [
      if (mark != null)
        LanguageMark.of(mark, element, document)
      else
        RawXml(source.substring(element.start, element.startTagEnd)),
      if (inner != null)
        ...inner
      else
        RawXml(source.substring(element.startTagEnd, element.endTagStart)),
      RawXml(source.substring(element.endTagStart, element.end)),
    ];
  }

  /// The template of everything between [element]'s tags, or null when it
  /// is kept as it is.
  List<PartNode>? childrenOf(SourceElement element) {
    List<PartNode>? out;
    var position = element.startTagEnd;
    for (final child in element.elements) {
      final nodes = node(child);
      if (nodes == null) continue;
      out ??= [];
      if (child.start > position) {
        out.add(RawXml(source.substring(position, child.start)));
      }
      out.addAll(nodes);
      position = child.end;
    }
    if (out == null) return null;
    if (element.endTagStart > position) {
      out.add(RawXml(source.substring(position, element.endTagStart)));
    }
    return out;
  }

  /// [element]'s whole template.
  List<PartNode> whole(SourceElement element) =>
      plain(element) ?? [RawXml(document.of(element))];

  /// The source of [node].
  String sourceOf(SourceNode node) => document.of(node);

  /// A slot for [element] from [atoms], or its plain template when it holds
  /// nothing to translate. [open] and [close] default to the start and end
  /// tags.
  List<PartNode>? slotOrPlain(
    SourceElement element,
    List<Atom> atoms, {
    required RunWriter writer,
    List<PartNode> Function()? open,
    List<PartNode> Function()? close,
  }) {
    final slot = buildSlot(
      atoms: atoms,
      table: table,
      open:
          open ??
          () => [RawXml(source.substring(element.start, element.startTagEnd))],
      close:
          close ??
          () => [RawXml(source.substring(element.endTagStart, element.end))],
      original: () => whole(element),
      writer: writer,
    );
    if (slot != null) return [slot];
    final kept = plain(element);
    return kept == null ? null : [UntranslatedScope(kept)];
  }
}
