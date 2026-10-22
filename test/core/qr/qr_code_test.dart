import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/qr/qr_code.dart';

import 'qr_reference_vectors.dart';

/// The matrix as `0`/`1` rows (or [dark]/[light]).
List<String> _rows(QrCode code, {String dark = '1', String light = '0'}) => [
  for (var y = 0; y < code.size; y++)
    [
      for (var x = 0; x < code.size; x++)
        if (code.isDark(x, y)) dark else light,
    ].join(),
];

String _digest(QrCode code) =>
    sha256.convert(utf8.encode(_rows(code).join('\n'))).toString();

Uint8List _modules(QrCode code) => Uint8List.fromList([
  for (var y = 0; y < code.size; y++)
    for (var x = 0; x < code.size; x++)
      if (code.isDark(x, y)) 1 else 0,
]);

/// Remainder of [value] divided by [generator] over GF(2).
int _polyRemainder(int value, int generator) {
  final degree = generator.bitLength - 1;
  var remainder = value;
  while (remainder.bitLength > degree) {
    remainder ^= generator << (remainder.bitLength - generator.bitLength);
  }
  return remainder;
}

/// The first copy of the format information, bit 14 first.
int _formatCopyA(QrCode code) {
  bool at(int x, int y) => code.isDark(x, y);
  final bits = <bool>[
    // Bits 0-7 run down column 8 (skipping the timing row), bits 8-14
    // run left along row 8 (skipping the timing column).
    for (var i = 0; i <= 5; i++) at(8, i),
    at(8, 7),
    at(8, 8),
    at(7, 8),
    for (var i = 9; i < 15; i++) at(14 - i, 8),
  ];
  return _bitsToInt(bits);
}

/// The second copy of the format information.
int _formatCopyB(QrCode code) {
  final size = code.size;
  final bits = <bool>[
    for (var i = 0; i < 8; i++) code.isDark(size - 1 - i, 8),
    for (var i = 8; i < 15; i++) code.isDark(8, size - 15 + i),
  ];
  return _bitsToInt(bits);
}

/// [bits] are least significant first.
int _bitsToInt(List<bool> bits) {
  var result = 0;
  for (var i = bits.length - 1; i >= 0; i--) {
    result = result << 1 | (bits[i] ? 1 : 0);
  }
  return result;
}

void _expectFinder(QrCode code, int left, int top) {
  for (var dy = -1; dy <= 7; dy++) {
    for (var dx = -1; dx <= 7; dx++) {
      final x = left + dx;
      final y = top + dy;
      if (x < 0 || y < 0 || x >= code.size || y >= code.size) continue;
      final ring = [dx, dy, 6 - dx, 6 - dy].reduce((a, b) => a < b ? a : b);
      // Ring 0 dark border, ring 1 light, rings 2+ the dark 3×3 core;
      // -1 the light separator.
      final dark = ring == 0 || ring >= 2;
      expect(
        code.isDark(x, y),
        dark,
        reason: 'finder at ($left, $top), module ($x, $y)',
      );
    }
  }
}

void _expectStructure(QrCode code) {
  final size = code.size;
  expect(size, code.version * 4 + 17);

  _expectFinder(code, 0, 0);
  _expectFinder(code, size - 7, 0);
  _expectFinder(code, 0, size - 7);

  // Timing patterns between the finders.
  for (var i = 8; i < size - 8; i++) {
    expect(code.isDark(i, 6), i.isEven, reason: 'timing row at $i');
    expect(code.isDark(6, i), i.isEven, reason: 'timing column at $i');
  }

  // Alignment patterns, except where they would cover a finder.
  final positions = qrAlignmentPositions(code.version);
  for (final cx in positions) {
    for (final cy in positions) {
      final overFinder =
          (cx == 6 && cy == 6) ||
          (cx == 6 && cy == positions.last) ||
          (cx == positions.last && cy == 6);
      if (overFinder) continue;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final ring = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
          expect(
            code.isDark(cx + dx, cy + dy),
            ring != 1,
            reason: 'alignment at ($cx, $cy)',
          );
        }
      }
    }
  }

  // The dark module.
  expect(code.isDark(8, size - 8), isTrue);

  // Both copies of the format information agree, decode to the level and
  // mask, and are a BCH(15, 5) codeword.
  final format = _formatCopyA(code);
  expect(_formatCopyB(code), format);
  expect(format, qrFormatBits(code.errorCorrection, code.mask));
  expect(_polyRemainder(format ^ 0x5412, 0x537), 0);
  final data = (format ^ 0x5412) >> 10;
  expect(data >> 3, code.errorCorrection.formatBits);
  expect(data & 7, code.mask);

  // Version information (7 and up), both copies.
  if (code.version >= 7) {
    final a = <bool>[];
    final b = <bool>[];
    for (var i = 0; i < 18; i++) {
      a.add(code.isDark(size - 11 + i % 3, i ~/ 3));
      b.add(code.isDark(i ~/ 3, size - 11 + i % 3));
    }
    final bits = _bitsToInt(a);
    expect(_bitsToInt(b), bits);
    expect(bits, qrVersionBits(code.version));
    expect(bits >> 12, code.version);
    expect(_polyRemainder(bits, 0x1F25), 0);
  }
}

void main() {
  group('QrCode.encode', () {
    group('matches the reference symbols', () {
      for (final vector in qrVectors) {
        test(
          '${jsonEncode(vector.text)} at ${vector.errorCorrection.name}',
          () {
            final code = QrCode.encode(
              vector.text,
              errorCorrection: vector.errorCorrection,
            );

            expect(code.version, vector.version);
            expect(code.errorCorrection, vector.errorCorrection);
            expect(code.mask, vector.mask);
            expect(_rows(code, dark: '#', light: '.'), vector.rows);
            _expectStructure(code);
          },
        );
      }
    });

    for (final (name, grid) in [
      ('filled to capacity', qrFullGrid),
      ('padded', qrPartialGrid),
    ]) {
      test('matches the reference at every version and level, $name', () {
        expect(grid, hasLength(160));
        for (final entry in grid) {
          final code = QrCode.encode(
            qrGridData(entry.length),
            errorCorrection: entry.errorCorrection,
          );
          final label = '${entry.errorCorrection.name} v${entry.version}';

          expect(code.version, entry.version, reason: label);
          expect(code.mask, entry.mask, reason: label);
          expect(_digest(code).substring(0, 16), entry.digest, reason: label);
          _expectStructure(code);
        }
      });
    }

    test('picks the smallest version that fits', () {
      for (final entry in qrFullGrid) {
        final level = entry.errorCorrection;
        expect(
          QrCode.byteCapacity(entry.version, level),
          entry.length,
          reason: '${level.name} v${entry.version}',
        );
        if (entry.version < 40) {
          expect(
            QrCode.encode(
              qrGridData(entry.length + 1),
              errorCorrection: level,
            ).version,
            entry.version + 1,
          );
        }
      }
    });

    test('knows the capacities of the standard', () {
      expect(QrCode.byteCapacity(1, QrErrorCorrection.low), 17);
      expect(QrCode.byteCapacity(1, QrErrorCorrection.medium), 14);
      expect(QrCode.byteCapacity(1, QrErrorCorrection.quartile), 11);
      expect(QrCode.byteCapacity(1, QrErrorCorrection.high), 7);
      expect(QrCode.byteCapacity(40, QrErrorCorrection.low), 2953);
      expect(QrCode.byteCapacity(40, QrErrorCorrection.medium), 2331);
      expect(QrCode.byteCapacity(40, QrErrorCorrection.quartile), 1663);
      expect(QrCode.byteCapacity(40, QrErrorCorrection.high), 1273);
      expect(
        () => QrCode.byteCapacity(0, QrErrorCorrection.low),
        throwsRangeError,
      );
      expect(
        () => QrCode.byteCapacity(41, QrErrorCorrection.low),
        throwsRangeError,
      );
    });

    test('counts UTF-8 bytes, not characters', () {
      // 7 characters, 21 bytes: too long for 1-H (7 bytes).
      final code = QrCode.encode(
        'வணக்கம்',
        errorCorrection: QrErrorCorrection.high,
      );

      expect(utf8.encode('வணக்கம்'), hasLength(21));
      expect(code.version, 3);
    });

    test('defaults to medium error correction', () {
      expect(QrCode.encode('Mozhi').errorCorrection, QrErrorCorrection.medium);
    });

    test('throws when the data does not fit version 40', () {
      expect(
        QrCode.encode(
          'a' * 2953,
          errorCorrection: QrErrorCorrection.low,
        ).version,
        40,
      );
      expect(
        () => QrCode.encode('a' * 2954, errorCorrection: QrErrorCorrection.low),
        throwsArgumentError,
      );
      expect(
        () =>
            QrCode.encode('a' * 1274, errorCorrection: QrErrorCorrection.high),
        throwsArgumentError,
      );
    });

    test('applies a forced mask', () {
      for (var mask = 0; mask < 8; mask++) {
        final code = QrCode.encode('Mozhi', mask: mask);

        expect(code.mask, mask);
        _expectStructure(code);
      }
      expect(() => QrCode.encode('Mozhi', mask: -1), throwsRangeError);
      expect(() => QrCode.encode('Mozhi', mask: 8), throwsRangeError);
    });

    test('chooses the mask with the lowest penalty', () {
      // Penalties of each mask as qrcodegen 1.8.0 scores them.
      const references = {
        'Mozhi': (
          QrErrorCorrection.medium,
          [1109, 1133, 1075, 1286, 1078, 1148, 1141, 1248],
        ),
        'https://example.org': (
          QrErrorCorrection.high,
          [1269, 1397, 1414, 1325, 1661, 1421, 1244, 1267],
        ),
      };
      for (final MapEntry(key: text, value: (level, penalties))
          in references.entries) {
        final scores = [
          for (var mask = 0; mask < 8; mask++)
            () {
              final code = QrCode.encode(
                text,
                errorCorrection: level,
                mask: mask,
              );
              return qrPenaltyScore(_modules(code), code.size);
            }(),
        ];
        expect(scores, penalties);
        final best = scores.indexOf(scores.reduce((a, b) => a < b ? a : b));
        expect(QrCode.encode(text, errorCorrection: level).mask, best);
      }
    });
  });

  group('isDark', () {
    test('throws outside the symbol', () {
      final code = QrCode.encode('Mozhi');

      expect(() => code.isDark(-1, 0), throwsRangeError);
      expect(() => code.isDark(0, 21), throwsRangeError);
      expect(code.isDark(0, 0), isTrue);
    });
  });

  group('qrAlignmentPositions', () {
    test('matches ISO/IEC 18004 annex E', () {
      // Table E.1, versions 2 to 40.
      const table = [
        [6, 18],
        [6, 22],
        [6, 26],
        [6, 30],
        [6, 34],
        [6, 22, 38],
        [6, 24, 42],
        [6, 26, 46],
        [6, 28, 50],
        [6, 30, 54],
        [6, 32, 58],
        [6, 34, 62],
        [6, 26, 46, 66],
        [6, 26, 48, 70],
        [6, 26, 50, 74],
        [6, 30, 54, 78],
        [6, 30, 56, 82],
        [6, 30, 58, 86],
        [6, 34, 62, 90],
        [6, 28, 50, 72, 94],
        [6, 26, 50, 74, 98],
        [6, 30, 54, 78, 102],
        [6, 28, 54, 80, 106],
        [6, 32, 58, 84, 110],
        [6, 30, 58, 86, 114],
        [6, 34, 62, 90, 118],
        [6, 26, 50, 74, 98, 122],
        [6, 30, 54, 78, 102, 126],
        [6, 26, 52, 78, 104, 130],
        [6, 30, 56, 82, 108, 134],
        [6, 34, 60, 86, 112, 138],
        [6, 30, 58, 86, 114, 142],
        [6, 34, 62, 90, 118, 146],
        [6, 30, 54, 78, 102, 126, 150],
        [6, 24, 50, 76, 102, 128, 154],
        [6, 28, 54, 80, 106, 132, 158],
        [6, 32, 58, 84, 110, 136, 162],
        [6, 26, 54, 82, 110, 138, 166],
        [6, 30, 58, 86, 114, 142, 170],
      ];

      expect(qrAlignmentPositions(1), isEmpty);
      for (var version = 2; version <= 40; version++) {
        expect(
          qrAlignmentPositions(version),
          table[version - 2],
          reason: 'version $version',
        );
      }
    });
  });

  group('qrFormatBits', () {
    test('matches ISO/IEC 18004 annex C', () {
      // Table C.1, masks 0 to 7.
      const table = {
        QrErrorCorrection.low: [
          0x77C4,
          0x72F3,
          0x7DAA,
          0x789D,
          0x662F,
          0x6318,
          0x6C41,
          0x6976,
        ],
        QrErrorCorrection.medium: [
          0x5412,
          0x5125,
          0x5E7C,
          0x5B4B,
          0x45F9,
          0x40CE,
          0x4F97,
          0x4AA0,
        ],
        QrErrorCorrection.quartile: [
          0x355F,
          0x3068,
          0x3F31,
          0x3A06,
          0x24B4,
          0x2183,
          0x2EDA,
          0x2BED,
        ],
        QrErrorCorrection.high: [
          0x1689,
          0x13BE,
          0x1CE7,
          0x19D0,
          0x0762,
          0x0255,
          0x0D0C,
          0x083B,
        ],
      };
      for (final MapEntry(key: level, value: bits) in table.entries) {
        expect(
          [for (var mask = 0; mask < 8; mask++) qrFormatBits(level, mask)],
          bits,
          reason: level.name,
        );
      }
    });
  });

  group('qrVersionBits', () {
    test('matches ISO/IEC 18004 annex D', () {
      expect(qrVersionBits(7), 0x07C94);
      expect(qrVersionBits(8), 0x085BC);
      expect(qrVersionBits(21), 0x15683);
      expect(qrVersionBits(40), 0x28C69);
    });
  });

  group('qrMaskInverts', () {
    test('follows the eight mask conditions', () {
      // Row 1 (y = 1) of each pattern from (0, 1) to (5, 1).
      const row1 = [
        '.#.#.#', // (x + y) mod 2
        '......', // y mod 2
        '#..#..', // x mod 3
        '..#..#', // (x + y) mod 3
        '###...', // (x/3 + y/2) mod 2
        '#.....', // xy mod 2 + xy mod 3
        '###...', // (xy mod 2 + xy mod 3) mod 2
        '...###', // ((x + y) mod 2 + xy mod 3) mod 2
      ];
      for (var mask = 0; mask < 8; mask++) {
        expect(
          [
            for (var x = 0; x < 6; x++)
              if (qrMaskInverts(mask, x, 1)) '#' else '.',
          ].join(),
          row1[mask],
          reason: 'mask $mask',
        );
      }
      expect(() => qrMaskInverts(8, 0, 0), throwsRangeError);
    });
  });

  group('qrPenaltyScore', () {
    test('matches qrcodegen on simple matrices', () {
      const size = 21;
      final light = Uint8List(size * size);
      final checker = Uint8List.fromList([
        for (var y = 0; y < size; y++)
          for (var x = 0; x < size; x++)
            if ((x + y).isEven) 1 else 0,
      ]);
      final finderLike = Uint8List(size * size)
        ..setAll(10 * size, [1, 0, 1, 1, 1, 0, 1]);

      expect(qrPenaltyScore(light, size), 2088);
      expect(qrPenaltyScore(checker, size), 0);
      expect(qrPenaltyScore(finderLike, size), 2104);
    });
  });
}
