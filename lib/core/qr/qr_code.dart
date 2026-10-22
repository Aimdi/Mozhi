import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// How much of a [QrCode] can be damaged and still be read (ISO/IEC 18004
/// error correction levels): about 7 %, 15 %, 25 % and 30 % of the
/// codewords.
enum QrErrorCorrection {
  low(1),
  medium(0),
  quartile(3),
  high(2);

  new(this.formatBits);

  /// The two bits that stand for the level in the format information.
  final int formatBits;
}

/// A QR Code symbol (ISO/IEC 18004 Model 2): a square of dark and light
/// modules.
///
/// [QrCode.encode] writes the text in byte mode (UTF-8) at the smallest
/// version (1 to 40) that holds it at the requested error correction level,
/// and picks the data mask with the lowest penalty score, as the standard
/// describes. The quiet zone (four light modules around the symbol) is not
/// part of the matrix: whoever draws the code adds it (see `QrCodeView`).
///
/// Pure Dart, no platform code: it runs the same on Android and the web.
final class QrCode {
  new _(this.version, this.errorCorrection, this.mask, this._modules)
    : size = version * 4 + 17;

  /// Encodes [data] as UTF-8 bytes in byte mode, at the smallest version
  /// that fits.
  ///
  /// Throws an [ArgumentError] when [data] is too long for version 40 at
  /// [errorCorrection] (2953 bytes at [QrErrorCorrection.low], 1273 at
  /// [QrErrorCorrection.high]).
  ///
  /// [mask] forces a data mask (0 to 7) instead of the one with the lowest
  /// penalty; only tests compare against other encoders that way.
  factory encode(
    String data, {
    QrErrorCorrection errorCorrection = QrErrorCorrection.medium,
    @visibleForTesting int? mask,
  }) {
    if (mask != null && (mask < 0 || mask > 7)) {
      throw RangeError.range(mask, 0, 7, 'mask');
    }
    final bytes = utf8.encode(data);
    final version = _smallestVersion(bytes.length, errorCorrection);
    if (version == null) {
      throw ArgumentError.value(
        '${bytes.length} bytes',
        'data',
        'Too long for a QR code at error correction ${errorCorrection.name}',
      );
    }
    final codewords = _codewords(bytes, version, errorCorrection);
    final builder = _MatrixBuilder(version)
      ..drawFunctionPatterns(errorCorrection)
      ..drawCodewords(codewords);
    final chosen = mask ?? builder.bestMask(errorCorrection);
    builder
      ..applyMask(chosen)
      ..drawFormatBits(errorCorrection, chosen);
    return QrCode._(version, errorCorrection, chosen, builder.modules);
  }

  /// The symbol version, 1 (21 × 21 modules) to 40 (177 × 177).
  final int version;

  /// The error correction level the symbol was encoded with.
  final QrErrorCorrection errorCorrection;

  /// The data mask pattern (0 to 7) applied to the symbol.
  final int mask;

  /// Modules per side (without the quiet zone): `4 × version + 17`.
  final int size;

  /// Row-major, `size × size`; 1 is dark.
  final Uint8List _modules;

  /// Whether the module in column [x] and row [y] (0-based, from the top
  /// left corner) is dark.
  ///
  /// Throws a [RangeError] outside `0 ≤ x, y < size`.
  bool isDark(int x, int y) {
    RangeError.checkValueInInterval(x, 0, size - 1, 'x');
    RangeError.checkValueInInterval(y, 0, size - 1, 'y');
    return _modules[y * size + x] == 1;
  }

  /// The largest number of UTF-8 bytes a symbol of [version] holds in byte
  /// mode at [errorCorrection].
  static int byteCapacity(int version, QrErrorCorrection errorCorrection) {
    RangeError.checkValueInInterval(version, 1, 40, 'version');
    final bits =
        _dataCodewords(version, errorCorrection) * 8 - 4 - _countBits(version);
    return bits ~/ 8;
  }

  /// The smallest version whose byte capacity at [ecl] holds [length]
  /// bytes, or null when none does.
  static int? _smallestVersion(int length, QrErrorCorrection ecl) {
    for (var version = 1; version <= 40; version++) {
      if (length <= byteCapacity(version, ecl)) return version;
    }
    return null;
  }

  /// Bits of the character count indicator in byte mode.
  static int _countBits(int version) => version < 10 ? 8 : 16;

  /// The final sequence of codewords: data (mode, count, bytes,
  /// terminator, padding) split into blocks, each followed by its
  /// Reed-Solomon error correction codewords, interleaved.
  static Uint8List _codewords(
    List<int> bytes,
    int version,
    QrErrorCorrection ecl,
  ) {
    final capacity = _dataCodewords(version, ecl);
    final bits = _BitBuffer()
      ..append(0x4, 4) // Byte mode.
      ..append(bytes.length, _countBits(version));
    for (final byte in bytes) {
      bits.append(byte, 8);
    }
    final capacityBits = capacity * 8;
    // Terminator (up to four zero bits), then zeros to a byte boundary.
    final terminator = capacityBits - bits.length;
    bits.append(0, terminator < 4 ? terminator : 4);
    bits.append(0, (8 - bits.length % 8) % 8);
    // Pad codewords, alternately 0xEC and 0x11.
    for (var pad = 0xEC; bits.length < capacityBits; pad ^= 0xEC ^ 0x11) {
      bits.append(pad, 8);
    }
    final data = bits.toBytes();

    final blockCount = _blocks[ecl.index][version];
    final eccLength = _eccPerBlock[ecl.index][version];
    final total = _rawDataModules(version) ~/ 8;
    final shortBlocks = blockCount - total % blockCount;
    final shortLength = total ~/ blockCount;
    final divisor = _reedSolomonDivisor(eccLength);

    final blocks = <Uint8List>[];
    var offset = 0;
    for (var i = 0; i < blockCount; i++) {
      final dataLength = shortLength - eccLength + (i < shortBlocks ? 0 : 1);
      final block = data.sublist(offset, offset + dataLength);
      offset += dataLength;
      final ecc = _reedSolomonRemainder(block, divisor);
      // Short blocks get a placeholder byte so every block has the same
      // length while interleaving; the placeholder is skipped below.
      blocks.add(
        Uint8List(shortLength + 1)
          ..setRange(0, dataLength, block)
          ..setRange(shortLength + 1 - eccLength, shortLength + 1, ecc),
      );
    }

    final result = Uint8List(total);
    var k = 0;
    for (var i = 0; i < shortLength + 1; i++) {
      for (var j = 0; j < blocks.length; j++) {
        if (i != shortLength - eccLength || j >= shortBlocks) {
          result[k++] = blocks[j][i];
        }
      }
    }
    assert(k == total, 'Every codeword is placed');
    return result;
  }

  /// Data codewords (without error correction) of [version] at [ecl].
  static int _dataCodewords(int version, QrErrorCorrection ecl) =>
      _rawDataModules(version) ~/ 8 -
      _eccPerBlock[ecl.index][version] * _blocks[ecl.index][version];

  /// Modules of [version] left for data and error correction once the
  /// function patterns and format/version information are drawn
  /// (including the remainder bits).
  static int _rawDataModules(int version) {
    var result = (16 * version + 128) * version + 64;
    if (version >= 2) {
      final alignments = version ~/ 7 + 2;
      result -= (25 * alignments - 10) * alignments - 55;
      if (version >= 7) result -= 36;
    }
    return result;
  }

  /// The Reed-Solomon generator polynomial of [degree] (coefficients from
  /// the highest power down, the leading 1 left out), over GF(2⁸) with the
  /// QR code's field polynomial x⁸ + x⁴ + x³ + x² + 1.
  static Uint8List _reedSolomonDivisor(int degree) {
    final result = Uint8List(degree)..[degree - 1] = 1;
    // Multiply by (x - α⁰)(x - α¹)…(x - α^(degree-1)).
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = _gfMultiply(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = _gfMultiply(root, 0x02);
    }
    return result;
  }

  /// The error correction codewords of [data]: the remainder of its
  /// polynomial divided by [divisor].
  static Uint8List _reedSolomonRemainder(List<int> data, Uint8List divisor) {
    final result = Uint8List(divisor.length);
    for (final byte in data) {
      final factor = byte ^ result[0];
      result
        ..setRange(0, result.length - 1, result, 1)
        ..[result.length - 1] = 0;
      for (var i = 0; i < result.length; i++) {
        result[i] ^= _gfMultiply(divisor[i], factor);
      }
    }
    return result;
  }

  /// Product of [x] and [y] in GF(2⁸) modulo 0x11D.
  static int _gfMultiply(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z;
  }

  /// Error correction codewords per block, by level then version (index 0
  /// unused). ISO/IEC 18004:2015, table 9.
  static const _eccPerBlock = [
    // dart format off
    [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28,
      30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30,
      30, 30, 30, 30, 30],
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28,
      26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
      28, 28, 28, 28, 28],
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28,
      28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30,
      30, 30, 30, 30, 30],
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28,
      28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
      30, 30, 30, 30, 30],
    // dart format on
  ];

  /// Error correction blocks, by level then version (index 0 unused).
  /// ISO/IEC 18004:2015, table 9.
  static const _blocks = [
    // dart format off
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9,
      10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17,
      17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47,
      49],
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
      23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62,
      65, 68],
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
      25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74,
      77, 81],
    // dart format on
  ];
}

/// The centre rows/columns of the alignment patterns of [version] (empty
/// for version 1). ISO/IEC 18004:2015, annex E.
@visibleForTesting
List<int> qrAlignmentPositions(int version) {
  if (version == 1) return const [];
  final count = version ~/ 7 + 2;
  final step = (version * 8 + count * 3 + 5) ~/ (count * 4 - 4) * 2;
  final result = [6];
  for (var position = version * 4 + 10; result.length < count;) {
    result.insert(1, position);
    position -= step;
  }
  return result;
}

/// The 15 format information bits for [errorCorrection] and [mask]:
/// BCH(15, 5) with generator 0x537, XORed with 0x5412.
@visibleForTesting
int qrFormatBits(QrErrorCorrection errorCorrection, int mask) {
  final data = errorCorrection.formatBits << 3 | mask;
  var remainder = data;
  for (var i = 0; i < 10; i++) {
    remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537);
  }
  return (data << 10 | remainder) ^ 0x5412;
}

/// The 18 version information bits of [version] (7 and up): BCH(18, 6)
/// with generator 0x1F25.
@visibleForTesting
int qrVersionBits(int version) {
  var remainder = version;
  for (var i = 0; i < 12; i++) {
    remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25);
  }
  return version << 12 | remainder;
}

/// Whether data mask [mask] inverts the module in column [x], row [y].
@visibleForTesting
bool qrMaskInverts(int mask, int x, int y) => switch (mask) {
  0 => (x + y).isEven,
  1 => y.isEven,
  2 => x % 3 == 0,
  3 => (x + y) % 3 == 0,
  4 => (x ~/ 3 + y ~/ 2).isEven,
  5 => x * y % 2 + x * y % 3 == 0,
  6 => (x * y % 2 + x * y % 3).isEven,
  7 => ((x + y) % 2 + x * y % 3).isEven,
  _ => throw RangeError.range(mask, 0, 7, 'mask'),
};

/// The penalty score of a finished symbol ([modules] row-major, 1 dark,
/// [size] per side), ISO/IEC 18004:2015 section 7.8.3: runs of five or
/// more modules of one colour (N1 = 3, plus one per extra module), 2 × 2
/// blocks of one colour (N2 = 3), finder-like 1:1:3:1:1 patterns with four
/// light modules on one side (N3 = 40; the area outside the symbol counts
/// as light), and the deviation of the dark share from 50 % (N4 = 10 per
/// 5 %). The lower the better.
@visibleForTesting
int qrPenaltyScore(Uint8List modules, int size) {
  var result = 0;
  for (var line = 0; line < size; line++) {
    result +=
        _linePenalty((i) => modules[line * size + i] == 1, size) +
        _linePenalty((i) => modules[i * size + line] == 1, size);
  }
  for (var y = 0; y < size - 1; y++) {
    for (var x = 0; x < size - 1; x++) {
      final colour = modules[y * size + x];
      if (colour == modules[y * size + x + 1] &&
          colour == modules[(y + 1) * size + x] &&
          colour == modules[(y + 1) * size + x + 1]) {
        result += 3;
      }
    }
  }
  var dark = 0;
  for (final module in modules) {
    dark += module;
  }
  final total = size * size;
  // The smallest k ≥ 0 with (45 - 5k) % ≤ dark / total ≤ (55 + 5k) %.
  final k = ((dark * 20 - total * 10).abs() + total - 1) ~/ total - 1;
  return result + k * 10;
}

/// N1 and N3 penalties of one row or column ([dark] by index).
int _linePenalty(bool Function(int) dark, int size) {
  var result = 0;
  var runDark = false;
  var run = 0;
  // Lengths of the last seven runs, newest first; the first run includes
  // the light area before the symbol.
  final history = List.filled(7, 0);
  void push(int length) {
    final first = history[0] == 0;
    history
      ..setRange(1, 7, history)
      ..[0] = first ? length + size : length;
  }

  for (var i = 0; i < size; i++) {
    if (dark(i) == runDark) {
      run++;
      if (run == 5) {
        result += 3;
      } else if (run > 5) {
        result++;
      }
    } else {
      push(run);
      if (!runDark) result += _finderLikePatterns(history) * 40;
      runDark = dark(i);
      run = 1;
    }
  }
  // End of the line: close a dark run, then the light area after it.
  if (runDark) {
    push(run);
    run = 0;
  }
  push(run + size);
  return result + _finderLikePatterns(history) * 40;
}

/// How many finder-like patterns (light 4+, dark 1, light 1, dark 3, light
/// 1, dark 1, light 4+, in units of the narrowest run) the run [history]
/// ends with: 0, 1 or 2 (light area on both sides).
int _finderLikePatterns(List<int> history) {
  final n = history[1];
  final core =
      n > 0 &&
      history[2] == n &&
      history[3] == n * 3 &&
      history[4] == n &&
      history[5] == n;
  return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0) +
      (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0);
}

/// Appends bits most significant first.
class _BitBuffer {
  final _bits = <int>[];

  int get length => _bits.length;

  void append(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _bits.add((value >> i) & 1);
    }
  }

  Uint8List toBytes() {
    final result = Uint8List(_bits.length ~/ 8);
    for (var i = 0; i < _bits.length; i++) {
      result[i >> 3] |= _bits[i] << (7 - (i & 7));
    }
    return result;
  }
}

/// Draws a symbol: function patterns, then data, then mask and format.
class _MatrixBuilder {
  new(this.version)
    : size = version * 4 + 17,
      modules = Uint8List((version * 4 + 17) * (version * 4 + 17)),
      _function = Uint8List((version * 4 + 17) * (version * 4 + 17));

  final int version;
  final int size;
  final Uint8List modules;

  /// 1 where a function pattern (or format/version information) is, so
  /// data and masks leave it alone.
  final Uint8List _function;

  void _set(int x, int y, {required bool dark}) {
    modules[y * size + x] = dark ? 1 : 0;
    _function[y * size + x] = 1;
  }

  void drawFunctionPatterns(QrErrorCorrection ecl) {
    // Timing patterns (the finders below overwrite their ends).
    for (var i = 0; i < size; i++) {
      _set(6, i, dark: i.isEven);
      _set(i, 6, dark: i.isEven);
    }
    _drawFinder(3, 3);
    _drawFinder(size - 4, 3);
    _drawFinder(3, size - 4);

    final positions = qrAlignmentPositions(version);
    final last = positions.length - 1;
    for (var i = 0; i <= last; i++) {
      for (var j = 0; j <= last; j++) {
        // Not over the three finder patterns.
        if ((i == 0 && j == 0) ||
            (i == 0 && j == last) ||
            (i == last && j == 0)) {
          continue;
        }
        _drawAlignment(positions[i], positions[j]);
      }
    }
    // Reserve the format areas (the real bits come with the mask).
    drawFormatBits(ecl, 0);
    _drawVersion();
  }

  /// A finder pattern centred on ([cx], [cy]), with its light separator.
  void _drawFinder(int cx, int cy) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final x = cx + dx;
        final y = cy + dy;
        if (x < 0 || x >= size || y < 0 || y >= size) continue;
        final distance = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        _set(x, y, dark: distance != 2 && distance != 4);
      }
    }
  }

  /// A 5 × 5 alignment pattern centred on ([cx], [cy]).
  void _drawAlignment(int cx, int cy) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final distance = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        _set(cx + dx, cy + dy, dark: distance != 1);
      }
    }
  }

  /// Both copies of the format information, and the dark module.
  void drawFormatBits(QrErrorCorrection ecl, int mask) {
    final bits = qrFormatBits(ecl, mask);
    bool bit(int i) => (bits >> i) & 1 == 1;
    // Around the top left finder.
    for (var i = 0; i <= 5; i++) {
      _set(8, i, dark: bit(i));
    }
    _set(8, 7, dark: bit(6));
    _set(8, 8, dark: bit(7));
    _set(7, 8, dark: bit(8));
    for (var i = 9; i < 15; i++) {
      _set(14 - i, 8, dark: bit(i));
    }
    // Split between the other two finders.
    for (var i = 0; i < 8; i++) {
      _set(size - 1 - i, 8, dark: bit(i));
    }
    for (var i = 8; i < 15; i++) {
      _set(8, size - 15 + i, dark: bit(i));
    }
    _set(8, size - 8, dark: true);
  }

  /// Both copies of the version information (version 7 and up).
  void _drawVersion() {
    if (version < 7) return;
    final bits = qrVersionBits(version);
    for (var i = 0; i < 18; i++) {
      final dark = (bits >> i) & 1 == 1;
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      _set(a, b, dark: dark);
      _set(b, a, dark: dark);
    }
  }

  /// Places [codewords] in the two-module-wide zigzag from the bottom
  /// right corner, skipping function modules and the vertical timing
  /// pattern. Modules left over (remainder bits) stay light.
  void drawCodewords(Uint8List codewords) {
    final bitCount = codewords.length * 8;
    var i = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      final upward = (right + 1) & 2 == 0;
      for (var vertical = 0; vertical < size; vertical++) {
        final y = upward ? size - 1 - vertical : vertical;
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          if (_function[y * size + x] == 1 || i >= bitCount) continue;
          modules[y * size + x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1;
          i++;
        }
      }
    }
    assert(i == bitCount, 'Every data bit is placed');
  }

  /// XORs data mask [mask] over the data modules (applying it twice undoes
  /// it).
  void applyMask(int mask) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (_function[y * size + x] == 0 && qrMaskInverts(mask, x, y)) {
          modules[y * size + x] ^= 1;
        }
      }
    }
  }

  /// The mask with the lowest penalty score (the first one on ties),
  /// scored with its format information drawn.
  int bestMask(QrErrorCorrection ecl) {
    var best = 0;
    var bestScore = -1;
    for (var mask = 0; mask < 8; mask++) {
      applyMask(mask);
      drawFormatBits(ecl, mask);
      final score = qrPenaltyScore(modules, size);
      if (bestScore < 0 || score < bestScore) {
        best = mask;
        bestScore = score;
      }
      applyMask(mask);
    }
    return best;
  }
}
