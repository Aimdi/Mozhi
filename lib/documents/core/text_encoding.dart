import 'dart:convert';
import 'dart:typed_data';

/// Character encodings recognised when reading a document.
enum TextEncoding {
  utf8,

  /// UTF-8 with a byte order mark (kept on output).
  utf8Bom,
  utf16le,
  utf16be,

  /// Legacy single-byte text (not valid UTF-8). Written back as UTF-8,
  /// since translations may contain characters Latin-1 cannot represent.
  latin1,
}

/// Thrown when bytes do not look like text at all (e.g. a binary file).
class BinaryContentException implements Exception {
  const new();

  @override
  String toString() => 'BinaryContentException: not a text file';
}

/// Text decoded from a file, with the encoding to use when writing it back.
class DecodedText {
  const new(this.text, this.encoding);

  final String text;
  final TextEncoding encoding;
}

/// Decodes [bytes], honouring UTF-8/UTF-16 byte order marks and falling
/// back to Latin-1 when the data is not valid UTF-8.
///
/// Throws [BinaryContentException] when the data contains NUL bytes
/// (without a UTF-16 byte order mark).
DecodedText decodeText(List<int> bytes) {
  if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
    return DecodedText(
      utf8.decode(bytes.sublist(3), allowMalformed: true),
      TextEncoding.utf8Bom,
    );
  }
  if (_startsWith(bytes, const [0xFF, 0xFE])) {
    return DecodedText(_decodeUtf16(bytes, 2, little: true), .utf16le);
  }
  if (_startsWith(bytes, const [0xFE, 0xFF])) {
    return DecodedText(_decodeUtf16(bytes, 2, little: false), .utf16be);
  }
  if (bytes.contains(0)) throw const BinaryContentException();
  try {
    return DecodedText(utf8.decode(bytes), TextEncoding.utf8);
  } on FormatException {
    return DecodedText(latin1.decode(bytes), TextEncoding.latin1);
  }
}

/// Encodes [text] for writing in [encoding] (Latin-1 sources become UTF-8).
Uint8List encodeText(String text, TextEncoding encoding) {
  switch (encoding) {
    case TextEncoding.utf8:
    case TextEncoding.latin1:
      return utf8.encode(text);
    case TextEncoding.utf8Bom:
      return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
    case TextEncoding.utf16le:
    case TextEncoding.utf16be:
      final little = encoding == TextEncoding.utf16le;
      final units = text.codeUnits;
      final out = Uint8List(2 + units.length * 2);
      out[0] = little ? 0xFF : 0xFE;
      out[1] = little ? 0xFE : 0xFF;
      for (var i = 0; i < units.length; i++) {
        final unit = units[i];
        final high = unit >> 8;
        final low = unit & 0xFF;
        out[2 + i * 2] = little ? low : high;
        out[3 + i * 2] = little ? high : low;
      }
      return out;
  }
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

String _decodeUtf16(List<int> bytes, int offset, {required bool little}) {
  final units = <int>[];
  for (var i = offset; i + 1 < bytes.length; i += 2) {
    units.add(
      little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}
