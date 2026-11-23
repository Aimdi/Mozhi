import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/qr/qr_code.dart';
import 'package:mozhi/core/qr/qr_decoder.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';

/// Renders [code] as an 8-bit grayscale (luma) image with [scale] pixels per
/// module, [quietModules] light modules on each side, and optional [rotation]
/// (0, 90, 180, 270 degrees clockwise).
({Uint8List luma, int width, int height}) _renderQr(
  QrCode code, {
  int scale = 6,
  int quietModules = 4,
  int darkLuma = 15,
  int lightLuma = 245,
  int rotation = 0,
}) {
  final totalModules = code.size + quietModules * 2;
  final side = totalModules * scale;
  final luma = Uint8List(side * side)..fillRange(0, side * side, lightLuma);

  for (var my = 0; my < code.size; my++) {
    for (var mx = 0; mx < code.size; mx++) {
      if (!code.isDark(mx, my)) continue;
      final (rx, ry) = switch (rotation) {
        90 => (code.size - 1 - my, mx),
        180 => (code.size - 1 - mx, code.size - 1 - my),
        270 => (my, code.size - 1 - mx),
        _ => (mx, my),
      };
      final px0 = (rx + quietModules) * scale;
      final py0 = (ry + quietModules) * scale;
      for (var dy = 0; dy < scale; dy++) {
        final row = (py0 + dy) * side + px0;
        for (var dx = 0; dx < scale; dx++) {
          luma[row + dx] = darkLuma;
        }
      }
    }
  }
  return (luma: luma, width: side, height: side);
}

/// Applies a slight perspective warp (homography) + bilinear sampling to a
/// rendered QR image to simulate a tilted camera view.
({Uint8List luma, int width, int height}) _perspectiveWarp(
  Uint8List src,
  int width,
  int height, {
  double tiltX = 0.08,
  double tiltY = 0.06,
  double angleRad = 0.12,
  int background = 235,
}) {
  final outW = (width * 1.25).round();
  final outH = (height * 1.25).round();
  final out = Uint8List(outW * outH)..fillRange(0, outW * outH, background);
  final cxOut = outW / 2.0;
  final cyOut = outH / 2.0;
  final cxSrc = width / 2.0;
  final cySrc = height / 2.0;
  final cosA = cos(-angleRad);
  final sinA = sin(-angleRad);

  for (var y = 0; y < outH; y++) {
    final ny = (y - cyOut) / (height / 2.0);
    for (var x = 0; x < outW; x++) {
      final nx = (x - cxOut) / (width / 2.0);
      final denom = 1.0 + tiltX * nx + tiltY * ny;
      if (denom <= 0.2) continue;
      final px = nx / denom;
      final py = ny / denom;
      final rx = px * cosA - py * sinA;
      final ry = px * sinA + py * cosA;
      final sx = rx * (width / 2.0) + cxSrc;
      final sy = ry * (height / 2.0) + cySrc;
      final ix = sx.floor();
      final iy = sy.floor();
      if (ix < 0 || ix >= width - 1 || iy < 0 || iy >= height - 1) continue;
      final fx = sx - ix;
      final fy = sy - iy;
      final v00 = src[iy * width + ix];
      final v10 = src[iy * width + ix + 1];
      final v01 = src[(iy + 1) * width + ix];
      final v11 = src[(iy + 1) * width + ix + 1];
      final v =
          v00 * (1 - fx) * (1 - fy) +
          v10 * fx * (1 - fy) +
          v01 * (1 - fx) * fy +
          v11 * fx * fy;
      out[y * outW + x] = v.round().clamp(0, 255);
    }
  }
  return (luma: out, width: outW, height: outH);
}

/// Builds a custom ISO/IEC 18004 v1-M QR matrix from raw mode bits (for
/// testing Numeric, Alphanumeric, and ECI modes alongside Byte mode).
Uint8List _encodeCustomV1M(List<int> dataBits) {
  const size = 21;
  // Data capacity for v1-M is 16 data codewords + 10 EC codewords = 26 bytes.
  final bits = List<int>.of(dataBits);
  const capacityBits = 16 * 8;
  final term = min(4, capacityBits - bits.length);
  for (var i = 0; i < term; i++) {
    bits.add(0);
  }
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  var pad = 0xEC;
  while (bits.length < capacityBits) {
    for (var i = 7; i >= 0; i--) {
      bits.add((pad >> i) & 1);
    }
    pad ^= 0xEC ^ 0x11;
  }
  final data = Uint8List(16);
  for (var i = 0; i < bits.length; i++) {
    data[i >> 3] |= bits[i] << (7 - (i & 7));
  }

  // GF(256) RS remainder for degree 10.
  int gfMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z;
  }

  final div = Uint8List(10)..[9] = 1;
  var root = 1;
  for (var i = 0; i < 10; i++) {
    for (var j = 0; j < 10; j++) {
      div[j] = gfMul(div[j], root);
      if (j + 1 < 10) div[j] ^= div[j + 1];
    }
    root = gfMul(root, 2);
  }
  final ecc = Uint8List(10);
  for (final byte in data) {
    final factor = byte ^ ecc[0];
    ecc
      ..setRange(0, 9, ecc, 1)
      ..[9] = 0;
    for (var i = 0; i < 10; i++) {
      ecc[i] ^= gfMul(div[i], factor);
    }
  }
  final codewords = Uint8List.fromList([...data, ...ecc]);

  // Draw onto a v1 matrix using mask 0.
  final modules = Uint8List(size * size);
  final fn = Uint8List(size * size);
  void setFn(int x, int y, {required bool dark}) {
    modules[y * size + x] = dark ? 1 : 0;
    fn[y * size + x] = 1;
  }

  for (var i = 0; i < size; i++) {
    setFn(6, i, dark: i.isEven);
    setFn(i, 6, dark: i.isEven);
  }
  void finder(int cx, int cy) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final x = cx + dx;
        final y = cy + dy;
        if (x < 0 || x >= size || y < 0 || y >= size) continue;
        final d = max(dx.abs(), dy.abs());
        setFn(x, y, dark: d != 2 && d != 4);
      }
    }
  }

  finder(3, 3);
  finder(size - 4, 3);
  finder(3, size - 4);

  final fmt = qrFormatBits(QrErrorCorrection.medium, 0);
  bool bit(int i) => ((fmt >> i) & 1) == 1;
  for (var i = 0; i <= 5; i++) {
    setFn(8, i, dark: bit(i));
  }
  setFn(8, 7, dark: bit(6));
  setFn(8, 8, dark: bit(7));
  setFn(7, 8, dark: bit(8));
  for (var i = 9; i < 15; i++) {
    setFn(14 - i, 8, dark: bit(i));
  }
  for (var i = 0; i < 8; i++) {
    setFn(size - 1 - i, 8, dark: bit(i));
  }
  for (var i = 8; i < 15; i++) {
    setFn(8, size - 15 + i, dark: bit(i));
  }
  setFn(8, size - 8, dark: true);

  var idx = 0;
  for (var right = size - 1; right >= 1; right -= 2) {
    if (right == 6) right = 5;
    final upward = ((right + 1) & 2) == 0;
    for (var vertical = 0; vertical < size; vertical++) {
      final y = upward ? size - 1 - vertical : vertical;
      for (var j = 0; j < 2; j++) {
        final x = right - j;
        if (fn[y * size + x] == 1) continue;
        var b = (codewords[idx >> 3] >> (7 - (idx & 7))) & 1;
        if (qrMaskInverts(0, x, y)) b ^= 1;
        modules[y * size + x] = b;
        idx++;
      }
    }
  }
  return modules;
}

void _appendBits(List<int> out, int value, int count) {
  for (var i = count - 1; i >= 0; i--) {
    out.add((value >> i) & 1);
  }
}

void main() {
  group('QrDecoder', () {
    test('round-trips PairingCode.link (mozhi://pair?code=...)', () {
      final pairing = PairingCode.generate(
        address: const [192, 168, 1, 42],
        port: 49152,
        random: Random(7),
      );
      expect(pairing.link, startsWith('mozhi://pair?code='));

      for (final ecl in QrErrorCorrection.values) {
        final code = QrCode.encode(pairing.link, errorCorrection: ecl);
        final img = _renderQr(code);
        final decoded = QrDecoder.decode(img.luma, img.width, img.height);
        expect(decoded, pairing.link, reason: 'ecl=${ecl.name}');
        expect(PairingCode.tryParse(decoded!), pairing);
      }
    });

    test('round-trips short, medium, and long UTF-8 payloads', () {
      const payloads = [
        'Hi',
        'Mozhi',
        'வணக்கம் உலகம் — Bonjour le monde — こんにちは 🌍',
        'https://mozhi.example.org/pair?code=ABCD1234EFGH5678JKMN9012&v=2',
      ];
      for (final text in payloads) {
        final code = QrCode.encode(text);
        final img = _renderQr(code, scale: 5);
        expect(
          QrDecoder.decode(img.luma, img.width, img.height),
          text,
          reason: 'payload="$text"',
        );
      }
    });

    test('round-trips versions 1 through 10 across all four EC levels', () {
      for (var version = 1; version <= 10; version++) {
        for (final ecl in QrErrorCorrection.values) {
          final cap = QrCode.byteCapacity(version, ecl);
          final payload = List.generate(
            cap,
            (i) => String.fromCharCode(0x21 + (i + version * 7) % 90),
          ).join();
          final code = QrCode.encode(payload, errorCorrection: ecl);
          expect(code.version, version);

          final img = _renderQr(code, scale: 4);
          expect(
            QrDecoder.decode(img.luma, img.width, img.height),
            payload,
            reason: 'v$version-${ecl.name}',
          );
        }
      }
    });

    test('handles different scales and quiet-zone margins', () {
      final code = QrCode.encode('mozhi://pair?code=0123456789ABCDEFGHJKMNPQ');
      for (final (scale, quiet) in [(2, 4), (3, 2), (5, 8), (10, 6), (12, 4)]) {
        final img = _renderQr(code, scale: scale, quietModules: quiet);
        expect(
          QrDecoder.decode(img.luma, img.width, img.height),
          'mozhi://pair?code=0123456789ABCDEFGHJKMNPQ',
          reason: 'scale=$scale quiet=$quiet',
        );
      }
    });

    test('decodes 90°, 180°, and 270° rotated QR codes automatically', () {
      const text = 'mozhi://pair?code=ROTATED90180270TEST';
      for (final versionPayload in [
        'v1-rot', // version 1 (no alignment pattern)
        text, // version 3 (with alignment pattern)
      ]) {
        final code = QrCode.encode(versionPayload);
        for (final rotation in const [0, 90, 180, 270]) {
          final img = _renderQr(code, rotation: rotation);
          expect(
            QrDecoder.decode(img.luma, img.width, img.height),
            versionPayload,
            reason: 'v${code.version} rotation=$rotation°',
          );
        }
      }
    });

    test('decodes perspective-warped and tilted camera frames', () {
      const text = 'mozhi://pair?code=PERSPECTIVEWARPTEST1234';
      final code = QrCode.encode(text, errorCorrection: QrErrorCorrection.high);
      final flat = _renderQr(code, scale: 8, quietModules: 5);

      for (final (tiltX, tiltY, angle) in [
        (0.08, 0.05, 0.08),
        (-0.07, 0.06, -0.10),
        (0.05, -0.07, 0.14),
      ]) {
        final warped = _perspectiveWarp(
          flat.luma,
          flat.width,
          flat.height,
          tiltX: tiltX,
          tiltY: tiltY,
          angleRad: angle,
        );
        expect(
          QrDecoder.decode(warped.luma, warped.width, warped.height),
          text,
          reason: 'tilt=($tiltX,$tiltY) angle=$angle',
        );
      }
    });

    test('decodes low-contrast, noisy, and unevenly lit frames', () {
      const text = 'mozhi://pair?code=UNEVENLIGHTINGNOISE99';
      final code = QrCode.encode(
        text,
        errorCorrection: QrErrorCorrection.quartile,
      );
      final base = _renderQr(code, scale: 7, darkLuma: 70, lightLuma: 155);
      final rng = Random(42);
      final lit = Uint8List(base.luma.length);

      // Strong diagonal illumination gradient (shadow -> bright) plus
      // uniform random sensor noise.
      for (var y = 0; y < base.height; y++) {
        for (var x = 0; x < base.width; x++) {
          final grad =
              ((x / base.width) * 90.0 + (y / base.height) * 40.0) - 65.0;
          final noise = rng.nextInt(17) - 8;
          lit[y * base.width +
              x] = (base.luma[y * base.width + x] + grad + noise).round().clamp(
            0,
            255,
          );
        }
      }

      expect(QrDecoder.decode(lit, base.width, base.height), text);
    });

    test('recovers corrupted data and format modules via RS & BCH', () {
      const text = 'mozhi://pair?code=REEDSOLOMONRECOVERY01';
      final code = QrCode.encode(text, errorCorrection: QrErrorCorrection.high);
      final img = _renderQr(code);

      // Corrupt several data modules in the lower-right interior AND 2 bits of
      // format info copy A (still well within H's 30% RS + BCH(15,5) recovery).
      final damaged = Uint8List.fromList(img.luma);
      void flipModule(int mx, int my) {
        final px0 = (mx + 4) * 6;
        final py0 = (my + 4) * 6;
        for (var dy = 0; dy < 6; dy++) {
          for (var dx = 0; dx < 6; dx++) {
            final idx = (py0 + dy) * img.width + (px0 + dx);
            damaged[idx] = damaged[idx] < 128 ? 245 : 15;
          }
        }
      }

      // Flip 2 bits of format copy A (BCH(15,5) corrects up to 3 bit errors).
      flipModule(8, 0);
      flipModule(8, 2);

      // Flip a cluster of 12 data modules in the interior.
      for (var dy = 0; dy < 3; dy++) {
        for (var dx = 0; dx < 4; dx++) {
          flipModule(11 + dx, 11 + dy);
        }
      }

      expect(QrDecoder.decode(damaged, img.width, img.height), text);
    });

    test('supports Numeric, Alphanumeric, and ECI + Byte modes', () {
      // Numeric mode: "01234567" (3 + 3 + 2 digits).
      final numBits = <int>[];
      _appendBits(numBits, 0x1, 4); // Numeric
      _appendBits(numBits, 8, 10); // count = 8
      _appendBits(numBits, 12, 10); // "012"
      _appendBits(numBits, 345, 10); // "345"
      _appendBits(numBits, 67, 7); // "67"
      expect(QrDecoder.decodeMatrix(_encodeCustomV1M(numBits), 21), '01234567');

      // Alphanumeric mode: "MOZHI 42$" (9 chars = 4 pairs + 1).
      const alpha = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';
      const alphaMsg = r'MOZHI 42$';
      final alphaBits = <int>[];
      _appendBits(alphaBits, 0x2, 4);
      _appendBits(alphaBits, alphaMsg.length, 9);
      for (var i = 0; i + 1 < alphaMsg.length; i += 2) {
        final v =
            alpha.indexOf(alphaMsg[i]) * 45 + alpha.indexOf(alphaMsg[i + 1]);
        _appendBits(alphaBits, v, 11);
      }
      _appendBits(alphaBits, alpha.indexOf(alphaMsg[alphaMsg.length - 1]), 6);
      expect(QrDecoder.decodeMatrix(_encodeCustomV1M(alphaBits), 21), alphaMsg);

      // ECI (26 = UTF-8) + Byte mode: "café"
      final eciBits = <int>[];
      _appendBits(eciBits, 0x7, 4); // ECI
      _appendBits(eciBits, 26, 8); // UTF-8
      _appendBits(eciBits, 0x4, 4); // Byte
      final utf8Bytes = [0x63, 0x61, 0x66, 0xC3, 0xA9];
      _appendBits(eciBits, utf8Bytes.length, 8);
      for (final b in utf8Bytes) {
        _appendBits(eciBits, b, 8);
      }
      expect(QrDecoder.decodeMatrix(_encodeCustomV1M(eciBits), 21), 'café');
    });

    test('returns null for blank, noisy, or undersized frames', () {
      expect(QrDecoder.decode(Uint8List(100), 10, 10), isNull);
      expect(QrDecoder.decode(Uint8List(10), 40, 40), isNull);
      final blank = Uint8List(100 * 100)..fillRange(0, 10000, 200);
      expect(QrDecoder.decode(blank, 100, 100), isNull);
      final rng = Random(99);
      final noise = Uint8List.fromList([
        for (var i = 0; i < 120 * 120; i++) rng.nextInt(256),
      ]);
      expect(QrDecoder.decode(noise, 120, 120), isNull);
    });
  });
}
