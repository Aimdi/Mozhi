import 'package:mozhi/documents/core/document_builder.dart' show containsLetter;
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:mozhi/documents/core/parsed_document.dart'
    show placeholder, placeholderPattern;

/// SpreadsheetML strings: the shared strings table (`si`, each translated
/// once however many cells use it), inline strings in worksheets (`is`)
/// and the text of cell comments (`comment/text`; the authors stay).
/// Plain and rich text (`r` runs with their own `rPr`) are supported;
/// phonetic readings (`rPh`) are dropped from translated strings.
/// Numbers, dates, formulas and their cached results are never strings
/// here, so they stay untouched. Drawings in worksheets (`xdr:cNvPr`) are
/// another part, whose alternative text is translated there.
final class SheetPartBuilder extends PartBuilder {
  new(super.document, super.table);

  @override
  bool isParagraph(SourceElement element) =>
      element.inNamespace(Ns.sheet) &&
      (element.localName == 'si' ||
          element.localName == 'is' ||
          (element.localName == 'text' &&
              (element.parent?.isA(Ns.sheet, 'comment') ?? false)));

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

/// Threaded comments (`xl/threadedComments/*.xml`): translates the `<text>` of
/// every `<threadedComment>`, including comments containing `<mentions>`.
///
/// Each `@mention` span `[startIndex, startIndex + length)` is replaced with
/// an immutable placeholder (`⟨1⟩`, `⟨2⟩`, …) during translation, then
/// restored verbatim on write-back with exact recomputed `startIndex` and
/// `length` attributes on every `<mention>`. Comments with malformed or
/// overlapping mention spans are kept verbatim.
final class ThreadedCommentsPartBuilder extends PartBuilder {
  new(super.document, super.table);

  @override
  List<PartNode>? node(SourceElement element) {
    if (element.isA(Ns.threadedComments, 'threadedComment')) {
      return _comment(element);
    }
    return super.node(element);
  }

  List<PartNode>? _comment(SourceElement comment) {
    final textEl = comment.child(Ns.threadedComments, 'text');
    if (textEl == null || textEl.elements.isNotEmpty || textEl.isSelfClosing) {
      return null;
    }
    final mentionsEl = comment.child(Ns.threadedComments, 'mentions');
    final mentionEls = mentionsEl == null
        ? const <SourceElement>[]
        : [
            for (final child in mentionsEl.elements)
              if (child.isA(Ns.threadedComments, 'mention')) child,
          ];
    if (mentionEls.isEmpty) {
      final slot = slotOrPlain(textEl, [
        TextAtom(textEl.text.replaceAll('\r\n', '\n'), RunContext.plain),
      ], writer: const _EscapedTextWriter());
      if (slot == null) return null;
      return [
        RawXml(source.substring(comment.start, textEl.start)),
        ...slot,
        RawXml(source.substring(textEl.end, comment.end)),
      ];
    }

    final rawText = textEl.text.replaceAll('\r\n', '\n');
    final parsed = <_MentionSpan>[];
    for (final mention in mentionEls) {
      final start = int.tryParse(mention.attribute('startIndex') ?? '');
      final length = int.tryParse(mention.attribute('length') ?? '');
      if (start == null ||
          length == null ||
          start < 0 ||
          length <= 0 ||
          start + length > rawText.length) {
        return null;
      }
      parsed.add(
        _MentionSpan(
          element: mention,
          start: start,
          length: length,
          text: rawText.substring(start, start + length),
        ),
      );
    }
    parsed.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < parsed.length; i++) {
      if (parsed[i - 1].start + parsed[i - 1].length > parsed[i].start) {
        return null;
      }
    }

    // Build segment text with placeholders for each mention span.
    final nonMention = StringBuffer();
    final withTokens = StringBuffer();
    final glueBefore = <bool>[];
    final glueAfter = <bool>[];
    var cursor = 0;
    for (var i = 0; i < parsed.length; i++) {
      final span = parsed[i];
      final before = rawText.substring(cursor, span.start);
      nonMention.write(before);
      withTokens
        ..write(before)
        ..write(placeholder(i + 1));
      final prevChar = span.start > 0 ? rawText[span.start - 1] : '';
      final afterPos = span.start + span.length;
      final nextChar = afterPos < rawText.length ? rawText[afterPos] : '';
      glueBefore.add(prevChar.isNotEmpty && prevChar.trim().isNotEmpty);
      glueAfter.add(nextChar.isNotEmpty && nextChar.trim().isNotEmpty);
      cursor = afterPos;
    }
    final tail = rawText.substring(cursor);
    nonMention.write(tail);
    withTokens.write(tail);

    if (!containsLetter(nonMention.toString())) return null;

    final fullWithTokens = withTokens.toString();
    final trimmed = fullWithTokens.trim();
    if (trimmed.isEmpty) return null;
    final leadEnd = fullWithTokens.indexOf(trimmed);
    final leadSpace = fullWithTokens.substring(0, leadEnd);
    final trailSpace = fullWithTokens.substring(leadEnd + trimmed.length);

    final segmentIndex = table.add(trimmed);
    final resolvedCache =
        Expando<
          ({String text, Map<SourceElement, ({int start, int length})> spans})
        >();

    ({String text, Map<SourceElement, ({int start, int length})> spans})?
    resolve(PartRenderer renderer) {
      final cached = resolvedCache[renderer];
      if (cached != null) return cached;
      final translation = renderer.translationOf(segmentIndex);
      if (translation == null) return null;
      final built = _restoreMentions(
        translation: translation.replaceAll('\r\n', '\n'),
        leadSpace: leadSpace,
        trailSpace: trailSpace,
        mentions: parsed,
        glueBefore: glueBefore,
        glueAfter: glueAfter,
      );
      resolvedCache[renderer] = built;
      return built;
    }

    // Build nodes for the entire <threadedComment>, splicing <text> and every
    // <mention> in document order.
    final out = <PartNode>[];
    var pos = comment.start;
    for (final child in comment.elements) {
      if (identical(child, textEl)) {
        if (child.start > pos) {
          out.add(RawXml(source.substring(pos, child.start)));
        }
        out.addAll([
          RawXml(source.substring(child.start, child.startTagEnd)),
          ComputedXml(source.substring(child.startTagEnd, child.endTagStart), (
            renderer,
          ) {
            final resolved = resolve(renderer);
            return resolved == null ? null : escapeXmlText(resolved.text);
          }),
          RawXml(source.substring(child.endTagStart, child.end)),
        ]);
        pos = child.end;
      } else if (identical(child, mentionsEl)) {
        if (child.start > pos) {
          out.add(RawXml(source.substring(pos, child.start)));
        }
        var mPos = child.start;
        for (final mChild in child.elements) {
          if (!mChild.isA(Ns.threadedComments, 'mention')) continue;
          if (mChild.start > mPos) {
            out.add(RawXml(source.substring(mPos, mChild.start)));
          }
          final startTag = source.substring(mChild.start, mChild.startTagEnd);
          out.add(
            ComputedXml(startTag, (renderer) {
              final span = resolve(renderer)?.spans[mChild];
              if (span == null) return null;
              return spliceAttributes(startTag, {
                'startIndex': '${span.start}',
                'length': '${span.length}',
              });
            }),
          );
          if (!mChild.isSelfClosing) {
            out.add(RawXml(source.substring(mChild.startTagEnd, mChild.end)));
          }
          mPos = mChild.end;
        }
        if (child.end > mPos) {
          out.add(RawXml(source.substring(mPos, child.end)));
        }
        pos = child.end;
      }
    }
    if (comment.end > pos) out.add(RawXml(source.substring(pos, comment.end)));
    return out;
  }

  static ({String text, Map<SourceElement, ({int start, int length})> spans})
  _restoreMentions({
    required String translation,
    required String leadSpace,
    required String trailSpace,
    required List<_MentionSpan> mentions,
    required List<bool> glueBefore,
    required List<bool> glueAfter,
  }) {
    final out = StringBuffer(leadSpace);
    final spans = Map<SourceElement, ({int start, int length})>.identity();
    final used = <int>{};
    var last = 0;

    for (final match in placeholderPattern.allMatches(translation)) {
      if (match.start < last) continue;
      final number = int.parse(match.group(1)!);
      if (number < 1 || number > mentions.length) continue;
      var before = translation.substring(last, match.start);
      last = match.end;
      if (!used.add(number)) {
        out.write(before);
        continue;
      }
      if (glueBefore[number - 1]) {
        before = before.replaceFirst(_trailingSpaces, '');
      }
      out.write(before);
      final mention = mentions[number - 1];
      final start = out.length;
      out.write(mention.text);
      spans[mention.element] = (start: start, length: mention.text.length);
      if (glueAfter[number - 1]) {
        while (last < translation.length &&
            (translation[last] == ' ' || translation[last] == '\t')) {
          last++;
        }
      }
    }
    out.write(translation.substring(last));

    // Never lose a mention if the engine dropped its placeholder.
    for (var number = 1; number <= mentions.length; number++) {
      if (used.contains(number)) continue;
      final mention = mentions[number - 1];
      if (!glueBefore[number - 1] && out.isNotEmpty) {
        final built = out.toString();
        if (!built.endsWith(' ') && !built.endsWith('\n')) {
          out.write(' ');
        }
      }
      final start = out.length;
      out.write(mention.text);
      spans[mention.element] = (start: start, length: mention.text.length);
    }

    out.write(trailSpace);
    return (text: out.toString(), spans: spans);
  }

  static final _trailingSpaces = RegExp(r'[ \t]+$');
}

final class _MentionSpan {
  const new({
    required this.element,
    required this.start,
    required this.length,
    required this.text,
  });

  final SourceElement element;
  final int start;
  final int length;
  final String text;
}

/// Elements that hold nothing but plain text ([paragraph] decides which),
/// written back as escaped text with their line breaks: legacy comments in
/// presentations.
final class PlainElementPartBuilder extends PartBuilder {
  new(super.document, super.table, {required this.paragraphs});

  /// Legacy presentation comments (`p:cm/p:text`).
  factory presentationComments(SourceDocument document, SegmentTable table) =>
      PlainElementPartBuilder(
        document,
        table,
        paragraphs: (element) =>
            element.isA(Ns.presentation, 'text') &&
            (element.parent?.isA(Ns.presentation, 'cm') ?? false),
      );

  final bool Function(SourceElement element) paragraphs;

  @override
  bool isParagraph(SourceElement element) =>
      element.elements.isEmpty && paragraphs(element);

  @override
  List<PartNode>? paragraph(SourceElement element) => slotOrPlain(element, [
    TextAtom(element.text.replaceAll('\r\n', '\n'), RunContext.plain),
  ], writer: const _EscapedTextWriter());
}

final class _EscapedTextWriter extends RunWriter {
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
