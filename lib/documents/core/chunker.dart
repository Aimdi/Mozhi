import 'package:equatable/equatable.dart';
import 'package:mozhi/documents/core/batch_codec.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';

export 'batch_codec.dart' show ChunkEncoding;

/// One piece of a segment that is translated as a whole: the segment
/// itself, or a part of an oversized segment.
class TranslationUnit extends Equatable {
  const new({required this.segment, required this.part, required this.text});

  final int segment;
  final int part;
  final String text;

  @override
  List<Object?> get props => [segment, part, text];
}

/// Units translated together in one request.
class Chunk extends Equatable {
  const new({required this.index, required this.units, required this.encoding});

  final int index;
  final List<TranslationUnit> units;
  final ChunkEncoding encoding;

  /// The text sent to the engine.
  String get payload =>
      BatchCodec.encode([for (final unit in units) unit.text], encoding);

  int get length => payload.length;

  /// Index of the first / last segment the chunk covers.
  int get firstSegment => units.first.segment;
  int get lastSegment => units.last.segment;

  /// Splits the engine's [output] into one translation per unit (null when
  /// the batch alignment was lost).
  List<String>? split(String output) =>
      BatchCodec.decode(output, units.length, encoding);

  @override
  List<Object?> get props => [index, units, encoding];
}

/// The chunks of a document and how to put their translations back
/// together.
class ChunkPlan extends Equatable {
  const new({required this.chunks, required this.separators});

  final List<Chunk> chunks;

  /// Per segment: the original text between its parts (empty for segments
  /// that were not split).
  final List<List<String>> separators;

  int get segmentCount => separators.length;

  /// Total characters sent (including batch markers).
  int get characterCount =>
      chunks.fold(0, (total, chunk) => total + chunk.length);

  /// Per-segment translations from per-chunk unit translations
  /// ([results] maps chunk index to one text per unit). A segment is null
  /// until all of its parts are translated.
  List<String?> assemble(Map<int, List<String>> results) {
    final parts = List<List<String?>>.generate(
      segmentCount,
      (segment) => List<String?>.filled(separators[segment].length + 1, null),
    );
    for (final MapEntry(key: index, value: translations) in results.entries) {
      if (index < 0 || index >= chunks.length) continue;
      final units = chunks[index].units;
      for (var i = 0; i < units.length && i < translations.length; i++) {
        parts[units[i].segment][units[i].part] = translations[i];
      }
    }
    return [
      for (var segment = 0; segment < segmentCount; segment++)
        if (parts[segment].contains(null))
          null
        else
          _join(parts[segment].cast<String>(), separators[segment]),
    ];
  }

  static String _join(List<String> parts, List<String> separators) {
    final buffer = StringBuffer(parts.first);
    for (var i = 1; i < parts.length; i++) {
      buffer
        ..write(separators[i - 1])
        ..write(parts[i]);
    }
    return buffer.toString();
  }

  @override
  List<Object?> get props => [chunks, separators];
}

/// Groups segments into chunks of at most [maxCharacters] (and at most
/// [maxUnits] texts), never splitting a segment unless it is longer than
/// [maxCharacters] on its own — then it is cut at line breaks, sentence
/// ends, spaces, or (last resort) anywhere outside a placeholder.
class Chunker {
  const new({this.maxCharacters = 1500, this.maxUnits = 40})
    : assert(maxCharacters >= 50, 'maxCharacters too small'),
      assert(maxUnits >= 1, 'maxUnits must be positive');

  final int maxCharacters;
  final int maxUnits;

  /// Batch encoding used for [format].
  static ChunkEncoding encodingFor(DocumentFormat format) => switch (format) {
    DocumentFormat.plainText || DocumentFormat.markdown => .paragraphs,
    // Office documents and e-books (W6-A): prose is batched as paragraphs;
    // slides and cells are short, so numbered markers keep them aligned.
    DocumentFormat.docx ||
    DocumentFormat.odt ||
    DocumentFormat.epub => .paragraphs,
    DocumentFormat.pptx ||
    DocumentFormat.odp ||
    DocumentFormat.xlsx ||
    DocumentFormat.ods => .markers,
    // Web pages: blocks of prose without line breaks (W6-B).
    DocumentFormat.html => .paragraphs,
    // Subtitles and string tables: short texts whose alignment matters.
    DocumentFormat.srt ||
    DocumentFormat.vtt ||
    DocumentFormat.json ||
    DocumentFormat.xliff ||
    DocumentFormat.androidStrings ||
    DocumentFormat.po ||
    DocumentFormat.csv ||
    DocumentFormat.tsv ||
    DocumentFormat.appleStrings ||
    DocumentFormat.xcstrings => .markers,
  };

  /// Plans the chunks for [document].
  ChunkPlan plan(ParsedDocument document) =>
      planSegments(document.segments, encodingFor(document.format));

  /// Plans the chunks for [segments], batching with [encoding].
  ChunkPlan planSegments(List<Segment> segments, ChunkEncoding encoding) {
    final units = <TranslationUnit>[];
    final separators = <List<String>>[];
    // Room for a marker (`⟦999⟧ `) and the newline before it.
    const overhead = 8;
    for (var i = 0; i < segments.length; i++) {
      final parts = splitText(segments[i].text, maxCharacters - overhead);
      separators.add([
        for (var k = 0; k < parts.length - 1; k++) parts[k].separator,
      ]);
      for (var k = 0; k < parts.length; k++) {
        units.add(TranslationUnit(segment: i, part: k, text: parts[k].text));
      }
    }

    final chunks = <Chunk>[];
    var current = <TranslationUnit>[];
    var size = 0;
    void flush() {
      if (current.isEmpty) return;
      var chunkEncoding = current.length == 1 ? ChunkEncoding.single : encoding;
      if (chunkEncoding == ChunkEncoding.paragraphs &&
          current.any((unit) => BatchCodec.hasBlankLine(unit.text))) {
        chunkEncoding = ChunkEncoding.markers;
      }
      chunks.add(
        Chunk(index: chunks.length, units: current, encoding: chunkEncoding),
      );
      current = [];
      size = 0;
    }

    for (final unit in units) {
      final cost = unit.text.length + overhead;
      if (current.isNotEmpty &&
          (size + cost > maxCharacters || current.length >= maxUnits)) {
        flush();
      }
      current.add(unit);
      size += cost;
    }
    flush();
    return ChunkPlan(chunks: chunks, separators: separators);
  }
}

/// A part of a split text and the original text that followed it.
typedef TextPart = ({String text, String separator});

final _sentenceEnd = RegExp(r'[.!?…。！？]["”’»)\]]*(?=\s)|[。！？]');
final _placeholderAt = RegExp(r'[⟨〈]\d*$');

/// Cuts [text] into parts of at most [max] characters (see [Chunker]).
/// Joining `part.text + part.separator` for all parts gives [text] back.
List<TextPart> splitText(String text, int max) {
  final parts = <TextPart>[];
  var rest = text;
  while (rest.length > max) {
    final cut = _cutPoint(rest, max);
    var end = cut;
    while (end > 0 && _isSpace(rest.codeUnitAt(end - 1))) {
      end--;
    }
    var next = cut;
    while (next < rest.length && _isSpace(rest.codeUnitAt(next))) {
      next++;
    }
    if (end == 0) {
      end = cut;
      next = cut;
    }
    parts.add((
      text: rest.substring(0, end),
      separator: rest.substring(end, next),
    ));
    rest = rest.substring(next);
  }
  parts.add((text: rest, separator: ''));
  return parts;
}

/// Where to cut [text] (longer than [max]) so the first part fits.
int _cutPoint(String text, int max) {
  final window = text.substring(0, max + 1);
  final minimum = max ~/ 3;

  final newline = window.lastIndexOf('\n');
  if (newline > minimum) return newline;

  var sentence = -1;
  for (final match in _sentenceEnd.allMatches(window)) {
    if (match.end <= max) sentence = match.end;
  }
  if (sentence > minimum) return sentence;

  for (var i = max; i > minimum; i--) {
    if (_isSpace(window.codeUnitAt(i))) return i;
  }

  // No good boundary: cut hard, but never inside a placeholder or a
  // surrogate pair.
  var cut = max;
  final open = _placeholderAt.firstMatch(text.substring(0, cut));
  if (open != null && open.start > 0) cut = open.start;
  final unit = text.codeUnitAt(cut - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) cut--;
  return cut;
}

bool _isSpace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
