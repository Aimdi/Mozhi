import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';

/// Part of a segment's content, as produced by the parsers.
sealed class Piece {
  const new();
}

/// Translatable text. [source] is the original document text, [text] what
/// the translator sees (they differ for line breaks inside a Markdown
/// quote, whose `> ` prefixes are not translated).
final class TextPiece extends Piece {
  const new(this.source, [String? text]) : text = text ?? source;

  final String source;
  final String text;
}

/// Content that must not be translated; becomes a numbered placeholder.
final class TokenPiece extends Piece {
  const new(this.nodes);

  new text(String text) : nodes = [TextNode(text)];

  /// What the placeholder renders (may contain segments, e.g. ICU plural
  /// variants).
  final List<DocNode> nodes;
}

/// Splits [text] into [TextPiece]s and [TokenPiece]s for every match of
/// [pattern].
List<Piece> protect(String text, RegExp? pattern) {
  if (pattern == null || text.isEmpty) return [TextPiece(text)];
  final pieces = <Piece>[];
  var last = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.end == match.start) continue;
    if (match.start > last) {
      pieces.add(TextPiece(text.substring(last, match.start)));
    }
    pieces.add(TokenPiece.text(match.group(0)!));
    last = match.end;
  }
  if (last < text.length) pieces.add(TextPiece(text.substring(last)));
  return pieces;
}

final _letter = RegExp(r'\p{L}', unicode: true);
final _leadingSpace = RegExp(r'^\s+');

/// The whitespace (`\s` of regular expressions) at the end of [text]. A
/// loop, as `\s+$` takes quadratic time on a long run of spaces before
/// the last word.
String _trailingSpace(String text) {
  var start = text.length;
  while (start > 0 && _isSpace(text.codeUnitAt(start - 1))) {
    start--;
  }
  return text.substring(start);
}

/// Whether [unit] matches `\s`.
bool _isSpace(int unit) =>
    unit == 0x20 ||
    (unit >= 0x09 && unit <= 0x0D) ||
    unit == 0xA0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200A) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202F ||
    unit == 0x205F ||
    unit == 0x3000 ||
    unit == 0xFEFF;

/// Whether [text] contains at least one letter (in any script).
bool containsLetter(String text) => _letter.hasMatch(text);

/// Collects template nodes and segments while a parser walks a document.
class DocumentBuilder {
  final _Nodes _nodes = _Nodes();
  final List<Segment> _segments = [];
  final List<SegmentNode> _segmentNodes = [];

  /// Number of segments created so far.
  int get segmentCount => _segments.length;

  /// Appends verbatim text.
  void literal(String text) => _nodes.addAll([TextNode(text)]);

  /// Appends arbitrary nodes (e.g. from [content]).
  void add(List<DocNode> nodes) => _nodes.addAll(nodes);

  /// Appends the nodes for [pieces] (see [content]).
  void addContent(
    List<Piece> pieces, {
    String lineBreak = '\n',
    String continuation = '',
    String? label,
    bool Function(String text)? accept,
    String Function(String text)? escape,
  }) => add(
    content(
      pieces,
      lineBreak: lineBreak,
      continuation: continuation,
      label: label,
      accept: accept,
      escape: escape,
    ),
  );

  /// Turns [pieces] into nodes: surrounding whitespace stays literal and the
  /// rest becomes one [Segment] — unless it holds no letters or [accept]
  /// rejects its text, in which case everything stays verbatim.
  ///
  /// [escape] encodes translated text for the document (see
  /// [SegmentNode.escape]).
  List<DocNode> content(
    List<Piece> pieces, {
    String lineBreak = '\n',
    String continuation = '',
    String? label,
    bool Function(String text)? accept,
    String Function(String text)? escape,
  }) {
    final items = _merge(pieces);
    final lead = StringBuffer();
    final trail = StringBuffer();

    // Move edge whitespace out of the segment.
    while (items.isNotEmpty) {
      final first = items.first;
      if (first is! TextPiece) break;
      if (first.text.trim().isEmpty) {
        lead.write(first.source);
        items.removeAt(0);
        continue;
      }
      final source = _leadingSpace.stringMatch(first.source) ?? '';
      lead.write(source);
      items[0] = TextPiece(
        first.source.substring(source.length),
        first.text.replaceFirst(_leadingSpace, ''),
      );
      break;
    }
    final trailing = <String>[];
    while (items.isNotEmpty) {
      final last = items.last;
      if (last is! TextPiece) break;
      if (last.text.trim().isEmpty) {
        trailing.insert(0, last.source);
        items.removeLast();
        continue;
      }
      final source = _trailingSpace(last.source);
      trailing.insert(0, source);
      items[items.length - 1] = TextPiece(
        last.source.substring(0, last.source.length - source.length),
        last.text.substring(
          0,
          last.text.length - _trailingSpace(last.text).length,
        ),
      );
      break;
    }
    trailing.forEach(trail.write);

    final plain = StringBuffer();
    for (final item in items) {
      if (item is TextPiece) plain.write(item.text);
    }
    final words = plain.toString();
    final translatable =
        containsLetter(words) && (accept == null || accept(words));

    final nodes = _Nodes()..addAll([TextNode(lead.toString())]);
    if (!translatable) {
      for (final item in items) {
        nodes.addAll(switch (item) {
          TextPiece(:final source) => [TextNode(source)],
          TokenPiece(nodes: final tokenNodes) => tokenNodes,
        });
      }
    } else {
      nodes.addAll([
        _segment(
          items,
          lineBreak: lineBreak,
          continuation: continuation,
          label: label,
          escape: escape,
        ),
      ]);
    }
    return (nodes..addAll([TextNode(trail.toString())])).list;
  }

  SegmentNode _segment(
    List<Piece> items, {
    required String lineBreak,
    required String continuation,
    String? label,
    String Function(String text)? escape,
  }) {
    final text = StringBuffer();
    final sourceParts = <String>[];
    final tokens = <List<DocNode>>[];
    final glueBefore = <bool>[];
    final glueAfter = <bool>[];
    var current = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      switch (items[i]) {
        case TextPiece(:final source, text: final value):
          text.write(value.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
          current.write(source);
        case TokenPiece(:final nodes):
          tokens.add(nodes);
          text.write(placeholder(tokens.length));
          sourceParts.add(current.toString());
          current = StringBuffer();
          glueBefore.add(_glued(items, i - 1, atEnd: true));
          glueAfter.add(_glued(items, i + 1, atEnd: false));
      }
    }
    sourceParts.add(current.toString());
    final index = _segments.length;
    _segments.add(Segment(text.toString(), label: label));
    final node = SegmentNode(
      segment: index,
      sourceParts: sourceParts,
      tokens: tokens,
      glueBefore: glueBefore,
      glueAfter: glueAfter,
      lineBreak: lineBreak,
      continuation: continuation,
      escape: escape,
    );
    _segmentNodes.add(node);
    return node;
  }

  /// Whether the piece at [index] touches its neighbouring placeholder
  /// without whitespace.
  static bool _glued(List<Piece> items, int index, {required bool atEnd}) {
    if (index < 0 || index >= items.length) return false;
    final item = items[index];
    if (item is! TextPiece) return true;
    final source = item.source;
    if (source.isEmpty) return false;
    final char = atEnd ? source[source.length - 1] : source[0];
    return char.trim().isNotEmpty;
  }

  /// Builds the document.
  ParsedDocument build(DocumentFormat format) => ParsedDocument(
    format: format,
    nodes: _nodes.list,
    segments: _segments,
    segmentNodes: _segmentNodes,
  );

  /// [pieces] with adjacent text merged and empty text dropped. The text is
  /// collected in buffers: merging strings one by one copies them again and
  /// again (quadratic time for text made of many small pieces).
  static List<Piece> _merge(List<Piece> pieces) {
    final merged = <Piece>[];
    final source = StringBuffer();
    final text = StringBuffer();
    void flush() {
      if (source.isEmpty && text.isEmpty) return;
      merged.add(TextPiece(source.toString(), text.toString()));
      source.clear();
      text.clear();
    }

    for (final piece in pieces) {
      switch (piece) {
        case TextPiece():
          source.write(piece.source);
          text.write(piece.text);
        case TokenPiece():
          flush();
          merged.add(piece);
      }
    }
    flush();
    return merged;
  }
}

/// Nodes with adjacent text merged and empty text dropped (collected in a
/// buffer, see [DocumentBuilder._merge]).
final class _Nodes {
  final List<DocNode> _list = [];
  final StringBuffer _text = StringBuffer();

  /// The nodes added so far.
  List<DocNode> get list {
    _flush();
    return _list;
  }

  void addAll(List<DocNode> nodes) {
    for (final node in nodes) {
      if (node is TextNode) {
        _text.write(node.text);
      } else {
        _flush();
        _list.add(node);
      }
    }
  }

  void _flush() {
    if (_text.isEmpty) return;
    _list.add(TextNode(_text.toString()));
    _text.clear();
  }
}
