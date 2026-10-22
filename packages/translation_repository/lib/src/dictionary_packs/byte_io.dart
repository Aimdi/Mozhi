import 'dart:convert';
import 'dart:typed_data';

/// Reads the little-endian integers and unsigned LEB128 varints of a
/// dictionary pack's binary sections. Throws [FormatException] past the
/// end.
final class PackByteReader {
  new(this.bytes, [this.position = 0]);

  final Uint8List bytes;
  int position;

  bool get isAtEnd => position >= bytes.length;

  int byte() {
    if (position >= bytes.length) {
      throw const FormatException('Unexpected end of pack data');
    }
    return bytes[position++];
  }

  /// An unsigned LEB128 varint of at most 5 bytes (32 bits).
  int varint() {
    var result = 0;
    for (var shift = 0; shift < 35; shift += 7) {
      final value = byte();
      result += (value & 0x7f) * (1 << shift);
      if (value & 0x80 == 0) return result;
    }
    throw const FormatException('Varint too long');
  }

  /// The next [length] bytes (a view, not a copy).
  Uint8List take(int length) {
    if (length < 0 || position + length > bytes.length) {
      throw const FormatException('Unexpected end of pack data');
    }
    final view = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    return view;
  }

  /// Skips [length] bytes.
  void skip(int length) => take(length);

  /// A varint length followed by that many UTF-8 bytes.
  String string() => utf8.decode(take(varint()));
}

/// Writes what [PackByteReader] reads.
final class PackByteWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  int get length => _builder.length;

  void byte(int value) => _builder.addByte(value);

  void bytes(List<int> value) => _builder.add(value);

  void varint(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError.value(value, 'value', 'Not a 32-bit unsigned value');
    }
    var rest = value;
    while (rest >= 0x80) {
      _builder.addByte((rest & 0x7f) | 0x80);
      rest = rest >> 7;
    }
    _builder.addByte(rest);
  }

  void string(String value) {
    final encoded = utf8.encode(value);
    varint(encoded.length);
    bytes(encoded);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

/// Compares [a] and [b] byte by byte (shorter first on a tie), the order of
/// a pack's keys.
int compareBytes(List<int> a, List<int> b) {
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final difference = a[i] - b[i];
    if (difference != 0) return difference;
  }
  return a.length - b.length;
}

/// Whether [bytes] starts with [prefix].
bool startsWithBytes(List<int> bytes, List<int> prefix) {
  if (prefix.length > bytes.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}
