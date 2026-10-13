import 'package:equatable/equatable.dart';
import 'package:mozhi/documents/core/document_format.dart';

/// Opening/closing characters of the numbered placeholders that stand for
/// protected spans (code, URLs, tags, ICU arguments) inside a [Segment].
const placeholderOpen = '⟨';
const placeholderClose = '⟩';

/// The placeholder text for protected span [number] (1-based).
String placeholder(int number) => '$placeholderOpen$number$placeholderClose';

/// Matches placeholders, tolerating spaces and CJK angle brackets that some
/// engines substitute.
final placeholderPattern = RegExp(r'[⟨〈]\s*(\d{1,4})\s*[⟩〉]');

/// A piece of natural-language text to translate.
///
/// [text] never has leading/trailing whitespace (that stays in the
/// document) and uses `\n` line breaks. Protected spans appear as numbered
/// placeholders (`⟨1⟩`) that the translation must keep.
class Segment extends Equatable {
  const Segment(this.text, {this.label});

  final String text;

  /// Optional location hint, e.g. a JSON key path or a cue number.
  final String? label;

  @override
  List<Object?> get props => [text, label];
}

/// A node of a parsed document's template.
sealed class DocNode {
  const DocNode();
}

/// Text copied verbatim to the output.
final class TextNode extends DocNode {
  const TextNode(this.text);

  final String text;

  @override
  String toString() => 'TextNode(${text.replaceAll('\n', r'\n')})';
}

/// The place of [Segment] number [segment]; renders its translation (or
/// the original text when untranslated).
final class SegmentNode extends DocNode {
  const SegmentNode({
    required this.segment,
    required this.sourceParts,
    required this.tokens,
    required this.glueBefore,
    required this.glueAfter,
    this.lineBreak = '\n',
    this.continuation = '',
  });

  final int segment;

  /// Original text around the protected spans:
  /// `sourceParts[0] + token 1 + sourceParts[1] + ... + token n +
  /// sourceParts[n]` is the original.
  final List<String> sourceParts;

  /// Content of each placeholder (index 0 is placeholder 1).
  final List<List<DocNode>> tokens;

  /// Whether placeholder `i + 1` directly follows / precedes non-space text
  /// in the original; spaces an engine inserts there are removed again.
  final List<bool> glueBefore;
  final List<bool> glueAfter;

  /// Line terminator used for line breaks in translations.
  final String lineBreak;

  /// Written after every line break of a translation (e.g. `> ` inside a
  /// Markdown quote, or list item indentation).
  final String continuation;
}

/// Content that is stored encoded in the document (e.g. a JSON string
/// literal): when nothing inside changes the [raw] original is kept,
/// otherwise the rendered [children] are passed through [encode].
final class EncodedNode extends DocNode {
  const EncodedNode({
    required this.raw,
    required this.children,
    required this.encode,
  });

  final String raw;
  final List<DocNode> children;
  final String Function(String decoded) encode;
}

/// A document split into translatable [segments] and a template ([nodes])
/// that rebuilds it.
///
/// `render()` (no translations) returns the original text exactly; so does
/// rendering every segment's own [Segment.text].
class ParsedDocument {
  ParsedDocument({
    required this.format,
    required List<DocNode> nodes,
    required List<Segment> segments,
    required List<SegmentNode> segmentNodes,
  }) : nodes = List.unmodifiable(nodes),
       segments = List.unmodifiable(segments),
       _segmentNodes = List.unmodifiable(segmentNodes);

  final DocumentFormat format;
  final List<DocNode> nodes;
  final List<Segment> segments;

  /// `_segmentNodes[i]` renders segment `i`.
  final List<SegmentNode> _segmentNodes;

  /// Number of characters the translator will see.
  int get characterCount =>
      segments.fold(0, (total, segment) => total + segment.text.length);

  bool get isEmpty => segments.isEmpty;

  /// Rebuilds the document with [translations] (indexed like [segments];
  /// null or missing entries keep the original text).
  ///
  /// With [bilingual], each translated segment is written after its
  /// original (separated by a line break) — meant for subtitles.
  String render([
    List<String?> translations = const [],
    bool bilingual = false,
  ]) {
    final buffer = StringBuffer();
    _Renderer(
      translations,
      segments: segments,
      bilingual: bilingual,
    ).write(buffer, nodes);
    return buffer.toString();
  }

  /// The original text of segment [index], with protected spans restored.
  String segmentSource(int index) {
    final buffer = StringBuffer();
    const _Renderer([]).write(buffer, [_segmentNodes[index]]);
    return buffer.toString();
  }

  /// How segment [index] renders with [translation].
  String segmentOutput(int index, String translation) {
    final translations = List<String?>.filled(segments.length, null);
    translations[index] = translation;
    final buffer = StringBuffer();
    _Renderer(
      translations,
      segments: segments,
    ).write(buffer, [_segmentNodes[index]]);
    return buffer.toString();
  }
}

class _Renderer {
  const _Renderer(
    this.translations, {
    this.segments = const [],
    this.bilingual = false,
  });

  final List<String?> translations;
  final List<Segment> segments;
  final bool bilingual;

  static const _identity = _Renderer([]);

  bool get _isIdentity => translations.isEmpty;

  void write(StringBuffer out, List<DocNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case TextNode(:final text):
          out.write(text);
        case SegmentNode():
          _writeSegment(out, node);
        case EncodedNode(:final raw, :final children, :final encode):
          if (_isIdentity) {
            out.write(raw);
          } else {
            final inner = _render(this, children);
            out.write(
              inner == _render(_identity, children) ? raw : encode(inner),
            );
          }
      }
    }
  }

  static String _render(_Renderer renderer, List<DocNode> nodes) {
    final buffer = StringBuffer();
    renderer.write(buffer, nodes);
    return buffer.toString();
  }

  void _writeOriginal(StringBuffer out, SegmentNode node) {
    for (var i = 0; i < node.sourceParts.length; i++) {
      out.write(node.sourceParts[i]);
      if (i < node.tokens.length) write(out, node.tokens[i]);
    }
  }

  void _writeSegment(StringBuffer out, SegmentNode node) {
    final translation = node.segment < translations.length
        ? translations[node.segment]
        : null;
    final unchanged =
        node.segment < segments.length &&
        translation == segments[node.segment].text;
    if (translation == null || unchanged) {
      _writeOriginal(out, node);
      return;
    }
    if (bilingual) {
      _writeOriginal(out, node);
      out
        ..write(node.lineBreak)
        ..write(node.continuation);
    }
    _writeTranslation(out, node, translation);
  }

  void _writeTranslation(
    StringBuffer out,
    SegmentNode node,
    String translation,
  ) {
    final text = translation.replaceAll('\r\n', '\n');
    final count = node.tokens.length;
    final used = <int>{};
    final newline = '${node.lineBreak}${node.continuation}';
    String lines(String value) => value.replaceAll('\n', newline);

    var last = 0;
    for (final match in placeholderPattern.allMatches(text)) {
      if (match.start < last) continue;
      final number = int.parse(match.group(1)!);
      if (number < 1 || number > count) continue;
      var before = text.substring(last, match.start);
      if (used.contains(number)) {
        // A duplicated placeholder: drop it.
        out.write(lines(before));
        last = match.end;
        continue;
      }
      if (node.glueBefore[number - 1]) {
        before = before.replaceFirst(_trailingSpaces, '');
      }
      out
        ..write(lines(before))
        ..write(_render(this, node.tokens[number - 1]));
      used.add(number);
      last = match.end;
      if (node.glueAfter[number - 1]) {
        while (last < text.length &&
            (text[last] == ' ' || text[last] == '\t')) {
          last++;
        }
      }
    }
    out.write(lines(text.substring(last)));

    // Never lose protected content (URLs, code, tags) an engine dropped.
    for (var number = 1; number <= count; number++) {
      if (used.contains(number)) continue;
      final content = _render(this, node.tokens[number - 1]);
      final separate = !node.glueBefore[number - 1] && text.isNotEmpty;
      out.write(separate ? ' $content' : content);
    }
  }

  static final _trailingSpaces = RegExp(r'[ \t]+$');
}
