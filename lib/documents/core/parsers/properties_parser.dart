import 'package:mozhi/documents/core/document_builder.dart';
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException, IcuMessageParser, looksLikeNaturalLanguage;
import 'package:mozhi/documents/core/parsers/locale_rules.dart'
    show LocalisationPatterns;
import 'package:mozhi/documents/core/parsers/markup_content.dart'
    show NodeList, hasSegment;
import 'package:mozhi/documents/core/parsers/xml_tree.dart'
    show checkDocumentLength;
import 'package:mozhi/documents/core/source_line.dart';
import 'package:translation_repository/translation_repository.dart'
    show ProtectedPatterns;

/// Parses Java `.properties` resource bundles ([DocumentFormat.properties]).
///
/// Preserves `#` and `!` comments, blank lines, keys, key-value separators
/// (`=`, `:` or whitespace), line continuations (`\`), and `\uXXXX` Unicode
/// escapes. `MessageFormat` placeholders (`{0}`, `{1, number}`,
/// `{1, plural, one {# item} other {# items}}`), template placeholders,
/// printf conversions, HTML tags, URLs and e-mail addresses are protected.
///
/// Throws [DocumentParseException] for malformed `\uXXXX` escapes or
/// oversized files.
ParsedDocument parseProperties(String text) {
  checkDocumentLength(text, 'Java properties');
  return _PropertiesParser(text).parse();
}

const _skipLeafKeys = {
  'url',
  'uri',
  'href',
  'src',
  'path',
  'filepath',
  'email',
  'mail',
  'color',
  'colour',
  'version',
  'uuid',
  'guid',
  'locale',
  'lang',
  'host',
  'hostname',
  'port',
  'ip',
  'hash',
  'checksum',
  'token',
  'secret',
  'regex',
  'regexp',
  'pattern',
  'class',
  'classname',
  'mime',
  'mimetype',
  'encoding',
  'date',
  'time',
  'timestamp',
};

final RegExp _propertiesFallback = ProtectedPatterns.combine([
  LocalisationPatterns.htmlTag,
  ProtectedPatterns.url,
  ProtectedPatterns.email,
  ProtectedPatterns.template,
  r'\{[^{}]*\}',
  LocalisationPatterns.printfInText,
]);

class _PropertiesParser {
  new(this.text) : lines = splitLines(text);

  final String text;
  final List<SourceLine> lines;
  final DocumentBuilder builder = DocumentBuilder();

  ParsedDocument parse() {
    final nodes = NodeList();
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      var content = line.content;
      var bom = '';
      if (i == 0 && content.startsWith('\uFEFF')) {
        bom = '\uFEFF';
        content = content.substring(1);
      }

      final trimmed = content.trimLeft();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('!')) {
        nodes.text(line.full);
        i++;
        continue;
      }

      // Collect logical line spanning `\` continuations.
      var end = i;
      while (end + 1 < lines.length &&
          _endsWithUnescapedBackslash(
            end == i ? content : lines[end].content,
          )) {
        end++;
      }

      final rawEntry = joinLines(lines, i, end + 1);
      final ending = lines[end].ending;

      // Join logical line content (dropping continuation `\` + newline + leading ws).
      final logical = _joinLogical(i, end, firstContent: content);
      final split = _splitKeyAndValue(logical.text);
      if (split == null) {
        nodes.text(rawEntry);
        i = end + 1;
        continue;
      }

      final keyDecoded = _decodeKey(split.rawKey, i);
      final leaf = keyDecoded.split('.').last.toLowerCase();
      if (_skipLeafKeys.contains(leaf) || split.rawValue.isEmpty) {
        nodes.text(rawEntry);
        i = end + 1;
        continue;
      }

      final valueDecoded = _decodeValue(split.rawValue, i);
      final hasUnicodeEscapes = _unicodeEscape.hasMatch(split.rawValue);
      final pieces = _messagePieces(valueDecoded, keyDecoded);
      final contentNodes = builder.content(
        pieces,
        label: keyDecoded,
        accept: looksLikeNaturalLanguage,
      );
      if (!hasSegment(contentNodes)) {
        nodes.text(rawEntry);
        i = end + 1;
        continue;
      }

      // Find exact raw prefix (up to start of value in rawEntry) so separator
      // formatting is preserved verbatim.
      final valueOffset = logical.rawOffsetAt(split.valueStart);
      final rawPrefix = '$bom${rawEntry.substring(bom.length, valueOffset)}';
      final rawValueSlice = rawEntry.substring(
        valueOffset,
        rawEntry.length - ending.length,
      );

      nodes
        ..text(rawPrefix)
        ..addAll([
          EncodedNode(
            raw: rawValueSlice,
            children: contentNodes,
            encode: (translated) =>
                _encodeValue(translated, escapeNonAscii: hasUnicodeEscapes),
          ),
        ])
        ..text(ending);
      i = end + 1;
    }

    builder.add(nodes.nodes);
    return builder.build(DocumentFormat.properties);
  }

  List<Piece> _messagePieces(String value, String label) {
    try {
      return IcuMessageParser(value, builder, label: label).parse();
    } on FormatException {
      return protect(value, _propertiesFallback);
    }
  }

  static bool _endsWithUnescapedBackslash(String line) {
    var count = 0;
    for (var i = line.length - 1; i >= 0 && line.codeUnitAt(i) == 0x5C; i--) {
      count++;
    }
    return count.isOdd;
  }

  /// Joins physical lines `start..end` (inclusive) into logical text while
  /// recording each logical character's offset inside the raw entry substring.
  ({String text, int Function(int logicalIndex) rawOffsetAt}) _joinLogical(
    int start,
    int end, {
    required String firstContent,
  }) {
    final buf = StringBuffer();
    final offsets = <int>[];
    var rawPos = 0;
    for (var k = start; k <= end; k++) {
      final line = lines[k];
      final rawContent = line.content;
      var contentStart = 0;
      if (k == start && rawContent.startsWith('\uFEFF')) {
        contentStart = 1;
      }
      if (k > start) {
        while (contentStart < rawContent.length &&
            _isPropSpace(rawContent.codeUnitAt(contentStart))) {
          contentStart++;
        }
      }
      final contentEnd = k < end ? rawContent.length - 1 : rawContent.length;
      for (var c = contentStart; c < contentEnd; c++) {
        buf.writeCharCode(rawContent.codeUnitAt(c));
        offsets.add(rawPos + c);
      }
      rawPos += rawContent.length + line.ending.length;
    }
    final text = buf.toString();
    return (
      text: text,
      rawOffsetAt: (index) => index < offsets.length ? offsets[index] : rawPos,
    );
  }

  ({String rawKey, String rawValue, int valueStart})? _splitKeyAndValue(
    String logical,
  ) {
    var pos = 0;
    while (pos < logical.length && _isPropSpace(logical.codeUnitAt(pos))) {
      pos++;
    }
    if (pos >= logical.length) return null;
    final keyStart = pos;
    while (pos < logical.length) {
      final unit = logical.codeUnitAt(pos);
      if (unit == 0x5C) {
        pos += pos + 1 < logical.length ? 2 : 1;
        continue;
      }
      if (unit == 0x3D || unit == 0x3A || _isPropSpace(unit)) break;
      pos++;
    }
    final rawKey = logical.substring(keyStart, pos);
    if (rawKey.isEmpty) return null;
    while (pos < logical.length && _isPropSpace(logical.codeUnitAt(pos))) {
      pos++;
    }
    if (pos < logical.length &&
        (logical.codeUnitAt(pos) == 0x3D || logical.codeUnitAt(pos) == 0x3A)) {
      pos++;
      while (pos < logical.length && _isPropSpace(logical.codeUnitAt(pos))) {
        pos++;
      }
    }
    return (rawKey: rawKey, rawValue: logical.substring(pos), valueStart: pos);
  }

  String _decodeKey(String raw, int lineIndex) =>
      _decodeEscapes(raw, lineIndex);

  String _decodeValue(String raw, int lineIndex) =>
      _decodeEscapes(raw, lineIndex);

  String _decodeEscapes(String raw, int lineIndex) {
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (ch != r'\') {
        out.write(ch);
        continue;
      }
      if (i + 1 >= raw.length) break;
      final next = raw[++i];
      switch (next) {
        case 't':
          out.write('\t');
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 'f':
          out.write('\f');
        case 'u':
          if (i + 4 >= raw.length) {
            throw DocumentParseException(
              'Java properties: line ${lineIndex + 1}: malformed \\uXXXX escape',
            );
          }
          final hex = raw.substring(i + 1, i + 5);
          final code = int.tryParse(hex, radix: 16);
          if (code == null) {
            throw DocumentParseException(
              'Java properties: line ${lineIndex + 1}: malformed \\u$hex escape',
            );
          }
          out.writeCharCode(code);
          i += 4;
        default:
          out.write(next);
      }
    }
    return out.toString();
  }

  static String _encodeValue(String value, {required bool escapeNonAscii}) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (i == 0 && (unit == 0x20 || unit == 0x09 || unit == 0x0C)) {
        out.write(unit == 0x20 ? r'\ ' : (unit == 0x09 ? r'\t' : r'\f'));
        continue;
      }
      switch (unit) {
        case 0x5C:
          out.write(r'\\');
        case 0x09:
          out.write(r'\t');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x0C:
          out.write(r'\f');
        default:
          if (escapeNonAscii && (unit < 0x20 || unit > 0x7E)) {
            out.write(
              '\\u${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}',
            );
          } else {
            out.writeCharCode(unit);
          }
      }
    }
    return out.toString();
  }

  static bool _isPropSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0C;

  static final _unicodeEscape = RegExp(r'\\u[0-9a-fA-F]{4}');
}
