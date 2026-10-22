import 'dart:typed_data';

/// gzip (RFC 1952) and DEFLATE (RFC 1951) in pure Dart, so dictionary packs
/// open the same way on Android and on the web (no `dart:io` codecs).
///
/// Decoding handles every DEFLATE block type (stored, fixed and dynamic
/// Huffman codes) and checks the gzip trailer (CRC-32 and length). The
/// encoder only writes stored (uncompressed) blocks: it is for packs built
/// in tests; the pack builder (`tool/dictionary_packs.py`) compresses with
/// zlib.

/// Decodes the single gzip member [data]. Throws [FormatException] for
/// anything that is not a valid gzip member or whose CRC-32 or length does
/// not match, and when the output would exceed [maxLength] bytes.
Uint8List gzipDecode(Uint8List data, {int maxLength = 1 << 24}) {
  if (data.length < 18 || data[0] != 0x1f || data[1] != 0x8b) {
    throw const FormatException('Not gzip data');
  }
  if (data[2] != 8) throw const FormatException('Unknown gzip method');
  final flags = data[3];
  if (flags & 0xe0 != 0) throw const FormatException('Reserved gzip flags');
  var position = 10;
  if (flags & 0x04 != 0) {
    _need(data, position + 2);
    position += 2 + (data[position] | data[position + 1] << 8);
  }
  if (flags & 0x08 != 0) position = _skipZeroTerminated(data, position);
  if (flags & 0x10 != 0) position = _skipZeroTerminated(data, position);
  if (flags & 0x02 != 0) position += 2;
  if (position + 8 > data.length) {
    throw const FormatException('Truncated gzip header');
  }
  final trailer = data.length - 8;
  final expectedCrc = _uint32(data, trailer);
  final expectedLength = _uint32(data, trailer + 4);
  if (expectedLength > maxLength) {
    throw FormatException('gzip data larger than $maxLength bytes');
  }
  final inflater = _Inflater(data, position, expectedLength, maxLength);
  final output = inflater.run();
  if (inflater.position > trailer) {
    throw const FormatException('Truncated gzip data');
  }
  if (output.length != expectedLength || crc32(output) != expectedCrc) {
    throw const FormatException('gzip checksum mismatch');
  }
  return output;
}

/// [data] as one gzip member with stored DEFLATE blocks (no compression),
/// readable by any gzip decoder.
Uint8List gzipEncodeStored(Uint8List data) {
  final builder = BytesBuilder(copy: false)
    // ID1 ID2 CM FLG MTIME(4) XFL OS (unknown).
    ..add(const [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]);
  var start = 0;
  do {
    final end = start + 0xffff < data.length ? start + 0xffff : data.length;
    final length = end - start;
    builder
      ..addByte(end == data.length ? 1 : 0)
      ..add([length & 0xff, length >> 8, ~length & 0xff, (~length >> 8) & 0xff])
      ..add(Uint8List.sublistView(data, start, end));
    start = end;
  } while (start < data.length);
  final crc = crc32(data);
  final length = data.length;
  builder.add([
    for (final value in [crc, length]) ...[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ],
  ]);
  return builder.takeBytes();
}

/// The CRC-32 (ISO-HDLC, as in gzip and zip) of [data], continuing [crc].
int crc32(List<int> data, [int crc = 0]) {
  final table = _crcTable;
  var value = crc ^ 0xffffffff;
  for (final byte in data) {
    value = table[(value ^ byte) & 0xff] ^ (value >>> 8);
  }
  return (value ^ 0xffffffff) & 0xffffffff;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
}();

void _need(Uint8List data, int end) {
  if (end > data.length) throw const FormatException('Truncated gzip header');
}

int _skipZeroTerminated(Uint8List data, int position) {
  var index = position;
  while (index < data.length && data[index] != 0) {
    index++;
  }
  _need(data, index + 1);
  return index + 1;
}

int _uint32(Uint8List data, int offset) =>
    data[offset] |
    data[offset + 1] << 8 |
    data[offset + 2] << 16 |
    data[offset + 3] << 24;

/// A canonical Huffman code: how many codes each length has and the
/// symbols ordered by code (as in zlib's `puff`).
final class _Huffman {
  new(List<int> lengths) : symbols = Uint16List(lengths.length) {
    for (final length in lengths) {
      counts[length]++;
    }
    var left = 1;
    for (var length = 1; length <= _maxBits; length++) {
      left = (left << 1) - counts[length];
      if (left < 0) throw const FormatException('Over-subscribed code');
    }
    final offsets = Uint16List(_maxBits + 1);
    for (var length = 1; length < _maxBits; length++) {
      offsets[length + 1] = offsets[length] + counts[length];
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length != 0) symbols[offsets[length]++] = symbol;
    }
  }

  static const _maxBits = 15;

  final Uint16List counts = Uint16List(_maxBits + 1);
  final Uint16List symbols;
}

const _lengthBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const _lengthExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const _distanceBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, //
  16385, 24577,
];
const _distanceExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];

/// The order code length code lengths are sent in.
const _codeLengthOrder = [
  16,
  17,
  18,
  0,
  8,
  7,
  9,
  6,
  10,
  5,
  11,
  4,
  12,
  3,
  13,
  2,
  14,
  1,
  15,
];

final _fixedLiterals = _Huffman([
  ...List.filled(144, 8),
  ...List.filled(112, 9),
  ...List.filled(24, 7),
  ...List.filled(8, 8),
]);
final _fixedDistances = _Huffman(List.filled(30, 5));

/// Inflates raw DEFLATE data starting at [position] of [_input].
final class _Inflater {
  new(this._input, this.position, int expected, this._maxLength)
    : _output = Uint8List(expected < 64 ? 64 : expected);

  final Uint8List _input;
  final int _maxLength;
  Uint8List _output;
  int _length = 0;

  /// The next input byte.
  int position;
  int _bitBuffer = 0;
  int _bitCount = 0;

  Uint8List run() {
    var last = false;
    while (!last) {
      last = _bits(1) == 1;
      switch (_bits(2)) {
        case 0:
          _stored();
        case 1:
          _codes(_fixedLiterals, _fixedDistances);
        case 2:
          _dynamic();
        default:
          throw const FormatException('Invalid DEFLATE block type');
      }
    }
    return Uint8List.sublistView(_output, 0, _length);
  }

  int _bits(int count) {
    while (_bitCount < count) {
      if (position >= _input.length) {
        throw const FormatException('Truncated DEFLATE data');
      }
      _bitBuffer |= _input[position++] << _bitCount;
      _bitCount += 8;
    }
    final value = _bitBuffer & ((1 << count) - 1);
    _bitBuffer >>= count;
    _bitCount -= count;
    return value;
  }

  void _stored() {
    // Skip to the byte boundary (fewer than 8 bits are buffered).
    _bitBuffer = 0;
    _bitCount = 0;
    if (position + 4 > _input.length) {
      throw const FormatException('Truncated DEFLATE data');
    }
    final length = _input[position] | _input[position + 1] << 8;
    final check = _input[position + 2] | _input[position + 3] << 8;
    if (length != (~check & 0xffff)) {
      throw const FormatException('Invalid stored block length');
    }
    position += 4;
    if (position + length > _input.length) {
      throw const FormatException('Truncated DEFLATE data');
    }
    _reserve(length);
    _output.setRange(_length, _length + length, _input, position);
    _length += length;
    position += length;
  }

  void _dynamic() {
    final literalCount = _bits(5) + 257;
    final distanceCount = _bits(5) + 1;
    final codeLengthCount = _bits(4) + 4;
    if (literalCount > 286 || distanceCount > 30) {
      throw const FormatException('Too many DEFLATE codes');
    }
    final codeLengths = List.filled(19, 0);
    for (var index = 0; index < codeLengthCount; index++) {
      codeLengths[_codeLengthOrder[index]] = _bits(3);
    }
    final codeLengthCode = _Huffman(codeLengths);
    final lengths = List.filled(literalCount + distanceCount, 0);
    var index = 0;
    while (index < lengths.length) {
      final symbol = _decode(codeLengthCode);
      if (symbol < 16) {
        lengths[index++] = symbol;
        continue;
      }
      var repeat = 0;
      var value = 0;
      if (symbol == 16) {
        if (index == 0) throw const FormatException('Repeat without length');
        value = lengths[index - 1];
        repeat = 3 + _bits(2);
      } else if (symbol == 17) {
        repeat = 3 + _bits(3);
      } else {
        repeat = 11 + _bits(7);
      }
      if (index + repeat > lengths.length) {
        throw const FormatException('Too many code lengths');
      }
      for (var count = 0; count < repeat; count++) {
        lengths[index++] = value;
      }
    }
    if (lengths[256] == 0) throw const FormatException('No end-of-block code');
    _codes(
      _Huffman(lengths.sublist(0, literalCount)),
      _Huffman(lengths.sublist(literalCount)),
    );
  }

  void _codes(_Huffman literals, _Huffman distances) {
    while (true) {
      final symbol = _decode(literals);
      if (symbol < 256) {
        _reserve(1);
        _output[_length++] = symbol;
        continue;
      }
      if (symbol == 256) return;
      final lengthSymbol = symbol - 257;
      if (lengthSymbol >= _lengthBase.length) {
        throw const FormatException('Invalid length code');
      }
      final length =
          _lengthBase[lengthSymbol] + _bits(_lengthExtra[lengthSymbol]);
      final distanceSymbol = _decode(distances);
      if (distanceSymbol >= _distanceBase.length) {
        throw const FormatException('Invalid distance code');
      }
      final distance =
          _distanceBase[distanceSymbol] + _bits(_distanceExtra[distanceSymbol]);
      if (distance > _length) throw const FormatException('Distance too far');
      _reserve(length);
      // Byte by byte: a copy may overlap what it writes.
      var from = _length - distance;
      for (var count = 0; count < length; count++) {
        _output[_length++] = _output[from++];
      }
    }
  }

  int _decode(_Huffman huffman) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var length = 1; length <= _Huffman._maxBits; length++) {
      code |= _bits(1);
      final count = huffman.counts[length];
      if (code - count < first) return huffman.symbols[index + code - first];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw const FormatException('Invalid Huffman code');
  }

  void _reserve(int count) {
    final needed = _length + count;
    if (needed <= _output.length) return;
    if (needed > _maxLength) {
      throw FormatException('DEFLATE data larger than $_maxLength bytes');
    }
    var size = _output.length * 2;
    while (size < needed) {
      size *= 2;
    }
    if (size > _maxLength) size = _maxLength;
    _output = Uint8List(size)..setRange(0, _length, _output);
  }
}
