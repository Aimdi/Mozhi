import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mozhi/core/qr/qr_code.dart';

/// Pure-Dart ISO/IEC 18004 (Model 2) QR Code decoder for 8-bit grayscale
/// (luma) camera frames and synthetic renders.
///
/// Handles versions 1–40 across all four error correction levels (L/M/Q/H),
/// arbitrary rotations (0°, 90°, 180°, 270°, and tilted frames), perspective
/// distortion via projective homography, uneven lighting via integral-image
/// adaptive thresholding (with global Otsu fallback), BCH(15, 5) format
/// recovery, GF(2⁸) Reed-Solomon error correction (Berlekamp-Massey, Chien
/// search, Forney algorithm), and Numeric, Alphanumeric, Byte (UTF-8 / ECI),
/// and ECI segments.
abstract final class QrDecoder {
  /// Decodes the first valid QR Code found in the row-major 8-bit [luma]
  /// frame of size [width] × [height], or returns `null` when none is found.
  static String? decode(Uint8List luma, int width, int height) {
    if (width < 21 || height < 21 || luma.length < width * height) {
      return null;
    }

    // 1. Adaptive integral-image threshold (handles uneven lighting, shadows,
    //    low contrast, and most synthetic renders).
    final otsu = _otsuThreshold(luma, width, height);
    final adaptive = _binarizeAdaptive(luma, width, height, otsu);
    final fromAdaptive = _decodeBinary(adaptive, width, height);
    if (fromAdaptive != null) return fromAdaptive;

    // 2. Global Otsu threshold fallback (ideal for crisp synthetic images or
    //    tight quiet zones where a local window overlaps uniform areas).
    final global = _binarizeGlobal(luma, width, height, otsu);
    final fromGlobal = _decodeBinary(global, width, height);
    if (fromGlobal != null) return fromGlobal;

    // 3. Tighter / gentler adaptive window fallback for steep gradients or
    //    very low contrast.
    final tight = _binarizeAdaptive(
      luma,
      width,
      height,
      otsu,
      windowDivisor: 14,
      bias: 0.96,
      minDelta: 2,
    );
    return _decodeBinary(tight, width, height);
  }

  /// Decodes a pre-sampled [size] × [size] row-major binary matrix (1 = dark,
  /// 0 = light) directly. Returns `null` when format, Reed-Solomon, or payload
  /// decoding fails.
  @visibleForTesting
  static String? decodeMatrix(Uint8List modules, int size) {
    if (size < 21 || (size - 17) % 4 != 0 || modules.length < size * size) {
      return null;
    }
    final version = (size - 17) ~/ 4;
    if (version < 1 || version > 40) return null;

    final format = _readFormatInfo(modules, size);
    if (format == null) return null;

    final rawCodewords = _readCodewords(modules, size, version, format.mask);
    if (rawCodewords == null) return null;

    final dataBytes = _deinterleaveAndCorrect(
      rawCodewords,
      version,
      format.errorCorrection,
    );
    if (dataBytes == null) return null;

    return _decodeBitStream(dataBytes, version);
  }

  /* ------------------------------------------------------------------------ */
  /* Binarization                                                             */
  /* ------------------------------------------------------------------------ */

  static int _otsuThreshold(Uint8List luma, int width, int height) {
    final total = width * height;
    final hist = Int32List(256);
    var sumAll = 0.0;
    for (var i = 0; i < total; i++) {
      final v = luma[i];
      hist[v]++;
      sumAll += v;
    }

    var sumB = 0.0;
    var wB = 0;
    var maxVariance = -1.0;
    var best = 128;

    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sumAll - sumB) / wF;
      final diff = mB - mF;
      final variance = wB * wF * diff * diff;
      if (variance > maxVariance) {
        maxVariance = variance;
        best = t;
      }
    }
    return best;
  }

  static Uint8List _binarizeGlobal(
    Uint8List luma,
    int width,
    int height,
    int threshold,
  ) {
    final total = width * height;
    final binary = Uint8List(total);
    for (var i = 0; i < total; i++) {
      binary[i] = luma[i] <= threshold ? 1 : 0;
    }
    return binary;
  }

  /// Integral-image adaptive thresholding (Bradley/Wellner with uniform-black
  /// Otsu fallback so large solid dark regions stay dark without turning
  /// shadowed quiet zones dark).
  static Uint8List _binarizeAdaptive(
    Uint8List luma,
    int width,
    int height,
    int otsu, {
    int windowDivisor = 8,
    double bias = 0.93,
    double minDelta = 9,
  }) {
    final stride = width + 1;
    final integral = Float64List(stride * (height + 1));

    for (var y = 0; y < height; y++) {
      var rowSum = 0.0;
      final rowOffset = y * width;
      final intRow = (y + 1) * stride;
      final prevRow = y * stride;
      for (var x = 0; x < width; x++) {
        rowSum += luma[rowOffset + x];
        integral[intRow + x + 1] = integral[prevRow + x + 1] + rowSum;
      }
    }

    final minDim = width < height ? width : height;
    final radius = max(4, minDim ~/ (windowDivisor * 2));
    final binary = Uint8List(width * height);

    for (var y = 0; y < height; y++) {
      final y0 = max(0, y - radius);
      final y1 = min(height - 1, y + radius);
      final topRow = y0 * stride;
      final botRow = (y1 + 1) * stride;
      final rowOffset = y * width;
      final dy = y1 - y0 + 1;

      for (var x = 0; x < width; x++) {
        final x0 = max(0, x - radius);
        final x1 = min(width - 1, x + radius);
        final count = dy * (x1 - x0 + 1);
        final sum =
            integral[botRow + x1 + 1] -
            integral[topRow + x1 + 1] -
            integral[botRow + x0] +
            integral[topRow + x0];
        final mean = sum / count;
        final px = luma[rowOffset + x];
        final thresh = min(mean * bias, mean - minDelta);
        final isDark = mean < 8 ? px <= otsu : px < thresh;
        binary[rowOffset + x] = isDark ? 1 : 0;
      }
    }
    return binary;
  }

  /* ------------------------------------------------------------------------ */
  /* Finder detection, geometry, homography & grid sampling                   */
  /* ------------------------------------------------------------------------ */

  static String? _decodeBinary(Uint8List binary, int width, int height) {
    final minDim = width < height ? width : height;
    final initialSkip = minDim > 420 ? 2 : 1;
    var finders = _findFinders(binary, width, height, skip: initialSkip);
    if (finders.length < 3 && initialSkip > 1) {
      finders = _findFinders(binary, width, height, skip: 1);
    }
    if (finders.length < 3) return null;

    final triples = _selectFinderTriples(finders);
    for (final triple in triples) {
      final decoded = _decodeFromTriple(binary, width, height, triple);
      if (decoded != null) return decoded;
    }
    return null;
  }

  static List<_FinderCandidate> _findFinders(
    Uint8List binary,
    int width,
    int height, {
    required int skip,
  }) {
    final candidates = <_FinderCandidate>[];
    final counts = Int32List(5);

    for (var y = 0; y < height; y += skip) {
      counts.fillRange(0, 5, 0);
      var state = 0;
      final rowOffset = y * width;

      for (var x = 0; x < width; x++) {
        if (binary[rowOffset + x] == 1) {
          // Dark pixel.
          if ((state & 1) == 1) state++;
          counts[state]++;
        } else {
          // Light pixel.
          if ((state & 1) == 0) {
            if (state == 4) {
              if (_foundFinderRatio(counts)) {
                _confirmFinder(binary, width, height, counts, y, x, candidates);
                counts[0] = counts[2];
                counts[1] = counts[3];
                counts[2] = counts[4];
                counts[3] = 1;
                counts[4] = 0;
                state = 3;
              } else {
                counts[0] = counts[2];
                counts[1] = counts[3];
                counts[2] = counts[4];
                counts[3] = 1;
                counts[4] = 0;
                state = 3;
              }
            } else {
              state++;
              counts[state]++;
            }
          } else {
            counts[state]++;
          }
        }
      }
      if (state == 4 && _foundFinderRatio(counts)) {
        _confirmFinder(binary, width, height, counts, y, width, candidates);
      }
    }

    candidates.sort((a, b) => b.count.compareTo(a.count));
    return candidates;
  }

  static bool _foundFinderRatio(Int32List counts, {bool relaxed = false}) {
    var total = 0;
    for (var i = 0; i < 5; i++) {
      final c = counts[i];
      if (c == 0) return false;
      total += c;
    }
    if (total < 7) return false;
    final moduleSize = total / 7.0;
    final maxVar = moduleSize * (relaxed ? 0.72 : (total < 14 ? 0.65 : 0.55));
    return (moduleSize - counts[0]).abs() < maxVar &&
        (moduleSize - counts[1]).abs() < maxVar &&
        (3.0 * moduleSize - counts[2]).abs() < 3.0 * maxVar &&
        (moduleSize - counts[3]).abs() < maxVar &&
        (moduleSize - counts[4]).abs() < maxVar;
  }

  static double _centerFromEnd(Int32List counts, int end) =>
      (end - counts[4] - counts[3]) - counts[2] / 2.0;

  static void _confirmFinder(
    Uint8List binary,
    int width,
    int height,
    Int32List stateCount,
    int row,
    int colEnd,
    List<_FinderCandidate> candidates,
  ) {
    final totalH =
        stateCount[0] +
        stateCount[1] +
        stateCount[2] +
        stateCount[3] +
        stateCount[4];
    var cx = _centerFromEnd(stateCount, colEnd);
    final ix = cx.floor().clamp(0, width - 1);

    final vertical = _crossCheckVertical(
      binary,
      width,
      height,
      row,
      ix,
      stateCount[2],
      totalH,
    );
    if (vertical == null) return;
    final cy = vertical.center;
    final iy = cy.floor().clamp(0, height - 1);

    final horizontal = _crossCheckHorizontal(
      binary,
      width,
      height,
      ix,
      iy,
      stateCount[2],
      totalH,
    );
    if (horizontal == null) return;
    cx = horizontal.center;

    // Require at least one diagonal 1:1:3:1:1 confirmation to filter out
    // barcode-like or text-like horizontal/vertical false positives.
    final diagOk =
        _crossCheckDiagonal(
          binary,
          width,
          height,
          cx.floor().clamp(0, width - 1),
          iy,
          1,
          1,
        ) ||
        _crossCheckDiagonal(
          binary,
          width,
          height,
          cx.floor().clamp(0, width - 1),
          iy,
          1,
          -1,
        );
    if (!diagOk) return;

    final moduleSize = (horizontal.total + vertical.total) / 14.0;
    for (final existing in candidates) {
      if (existing.matches(cx, cy, moduleSize)) {
        existing.combine(cx, cy, moduleSize);
        return;
      }
    }
    candidates.add(_FinderCandidate(cx, cy, moduleSize));
  }

  static ({double center, int total})? _crossCheckVertical(
    Uint8List binary,
    int width,
    int height,
    int startRow,
    int centerCol,
    int maxCount,
    int originalTotal,
  ) {
    final counts = Int32List(5);
    var i = startRow;
    while (i >= 0 && binary[i * width + centerCol] == 1) {
      counts[2]++;
      i--;
    }
    if (i < 0) return null;
    while (i >= 0 &&
        binary[i * width + centerCol] == 0 &&
        counts[1] <= maxCount) {
      counts[1]++;
      i--;
    }
    if (i < 0 || counts[1] > maxCount) return null;
    while (i >= 0 &&
        binary[i * width + centerCol] == 1 &&
        counts[0] <= maxCount) {
      counts[0]++;
      i--;
    }
    if (counts[0] > maxCount) return null;

    i = startRow + 1;
    while (i < height && binary[i * width + centerCol] == 1) {
      counts[2]++;
      i++;
    }
    if (i == height) return null;
    while (i < height &&
        binary[i * width + centerCol] == 0 &&
        counts[3] < maxCount) {
      counts[3]++;
      i++;
    }
    if (i == height || counts[3] >= maxCount) return null;
    while (i < height &&
        binary[i * width + centerCol] == 1 &&
        counts[4] < maxCount) {
      counts[4]++;
      i++;
    }
    if (counts[4] >= maxCount) return null;

    final total = counts[0] + counts[1] + counts[2] + counts[3] + counts[4];
    if (5 * (total - originalTotal).abs() >= 2 * originalTotal) return null;
    if (!_foundFinderRatio(counts)) return null;
    return (center: _centerFromEnd(counts, i), total: total);
  }

  static ({double center, int total})? _crossCheckHorizontal(
    Uint8List binary,
    int width,
    int height,
    int startCol,
    int centerRow,
    int maxCount,
    int originalTotal,
  ) {
    final counts = Int32List(5);
    final rowOffset = centerRow * width;
    var j = startCol;
    while (j >= 0 && binary[rowOffset + j] == 1) {
      counts[2]++;
      j--;
    }
    if (j < 0) return null;
    while (j >= 0 && binary[rowOffset + j] == 0 && counts[1] <= maxCount) {
      counts[1]++;
      j--;
    }
    if (j < 0 || counts[1] > maxCount) return null;
    while (j >= 0 && binary[rowOffset + j] == 1 && counts[0] <= maxCount) {
      counts[0]++;
      j--;
    }
    if (counts[0] > maxCount) return null;

    j = startCol + 1;
    while (j < width && binary[rowOffset + j] == 1) {
      counts[2]++;
      j++;
    }
    if (j == width) return null;
    while (j < width && binary[rowOffset + j] == 0 && counts[3] < maxCount) {
      counts[3]++;
      j++;
    }
    if (j == width || counts[3] >= maxCount) return null;
    while (j < width && binary[rowOffset + j] == 1 && counts[4] < maxCount) {
      counts[4]++;
      j++;
    }
    if (counts[4] >= maxCount) return null;

    final total = counts[0] + counts[1] + counts[2] + counts[3] + counts[4];
    if (5 * (total - originalTotal).abs() >= 2 * originalTotal) return null;
    if (!_foundFinderRatio(counts)) return null;
    return (center: _centerFromEnd(counts, j), total: total);
  }

  static bool _crossCheckDiagonal(
    Uint8List binary,
    int width,
    int height,
    int centerX,
    int centerY,
    int dx,
    int dy,
  ) {
    final counts = Int32List(5);
    bool inBounds(int x, int y) => x >= 0 && x < width && y >= 0 && y < height;

    var step = 0;
    while (inBounds(centerX - step * dx, centerY - step * dy) &&
        binary[(centerY - step * dy) * width + (centerX - step * dx)] == 1) {
      counts[2]++;
      step++;
    }
    if (!inBounds(centerX - step * dx, centerY - step * dy)) return false;
    while (inBounds(centerX - step * dx, centerY - step * dy) &&
        binary[(centerY - step * dy) * width + (centerX - step * dx)] == 0) {
      counts[1]++;
      step++;
    }
    if (counts[1] == 0 || !inBounds(centerX - step * dx, centerY - step * dy)) {
      return false;
    }
    while (inBounds(centerX - step * dx, centerY - step * dy) &&
        binary[(centerY - step * dy) * width + (centerX - step * dx)] == 1) {
      counts[0]++;
      step++;
    }
    if (counts[0] == 0) return false;

    step = 1;
    while (inBounds(centerX + step * dx, centerY + step * dy) &&
        binary[(centerY + step * dy) * width + (centerX + step * dx)] == 1) {
      counts[2]++;
      step++;
    }
    if (!inBounds(centerX + step * dx, centerY + step * dy)) return false;
    while (inBounds(centerX + step * dx, centerY + step * dy) &&
        binary[(centerY + step * dy) * width + (centerX + step * dx)] == 0) {
      counts[3]++;
      step++;
    }
    if (counts[3] == 0 || !inBounds(centerX + step * dx, centerY + step * dy)) {
      return false;
    }
    while (inBounds(centerX + step * dx, centerY + step * dy) &&
        binary[(centerY + step * dy) * width + (centerX + step * dx)] == 1) {
      counts[4]++;
      step++;
    }
    if (counts[4] == 0) return false;

    return _foundFinderRatio(counts, relaxed: true);
  }

  static List<_FinderTriple> _selectFinderTriples(
    List<_FinderCandidate> candidates,
  ) {
    final limit = min(candidates.length, 12);
    final triples = <_FinderTriple>[];

    for (var i = 0; i < limit; i++) {
      for (var j = i + 1; j < limit; j++) {
        for (var k = j + 1; k < limit; k++) {
          final a = candidates[i];
          final b = candidates[j];
          final c = candidates[k];

          final minMod = min(a.moduleSize, min(b.moduleSize, c.moduleSize));
          final maxMod = max(a.moduleSize, max(b.moduleSize, c.moduleSize));
          if (maxMod / minMod > 1.75) continue;

          final dAB = _distSq(a, b);
          final dBC = _distSq(b, c);
          final dCA = _distSq(c, a);

          // The longest side is the hypotenuse between TR and BL; the
          // opposite vertex is TL.
          final _FinderCandidate tl;
          _FinderCandidate p1;
          _FinderCandidate p2;
          if (dBC >= dAB && dBC >= dCA) {
            tl = a;
            p1 = b;
            p2 = c;
          } else if (dCA >= dAB && dCA >= dBC) {
            tl = b;
            p1 = a;
            p2 = c;
          } else {
            tl = c;
            p1 = a;
            p2 = b;
          }

          final l1 = sqrt(_distSq(tl, p1));
          final l2 = sqrt(_distSq(tl, p2));
          if (l1 < 10.0 || l2 < 10.0) continue;

          final legRatio = min(l1, l2) / max(l1, l2);
          if (legRatio < 0.50) continue;

          final v1x = p1.x - tl.x;
          final v1y = p1.y - tl.y;
          final v2x = p2.x - tl.x;
          final v2y = p2.y - tl.y;
          final cosAngle = (v1x * v2x + v1y * v2y) / (l1 * l2);
          if (cosAngle.abs() > 0.50) continue;

          // Orient TR and BL via cross product: in screen coordinates
          // (x right, y down), cross(TR - TL, BL - TL) > 0 for every
          // rotation (0°, 90°, 180°, 270°, and any oblique angle).
          final cross = v1x * v2y - v1y * v2x;
          if (cross < 0) {
            final tmp = p1;
            p1 = p2;
            p2 = tmp;
          }

          final avgMod = (tl.moduleSize + p1.moduleSize + p2.moduleSize) / 3.0;
          final estDim = (l1 + l2) / (2.0 * avgMod) + 7.0;
          if (estDim < 16.0 || estDim > 190.0) continue;

          final sizeSpread = (maxMod - minMod) / avgMod;
          final score =
              sizeSpread * 2.5 +
              (1.0 - legRatio) * 2.0 +
              cosAngle.abs() * 2.0 -
              min(tl.count + p1.count + p2.count, 30) * 0.02;
          triples.add(_FinderTriple(tl: tl, tr: p1, bl: p2, score: score));
        }
      }
    }

    triples.sort((a, b) => a.score.compareTo(b.score));
    return triples.length > 6 ? triples.sublist(0, 6) : triples;
  }

  static double _distSq(_FinderCandidate a, _FinderCandidate b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return dx * dx + dy * dy;
  }

  static String? _decodeFromTriple(
    Uint8List binary,
    int width,
    int height,
    _FinderTriple triple,
  ) {
    final tl = triple.tl;
    final tr = triple.tr;
    final bl = triple.bl;

    final moduleSize = _estimateModuleSize(binary, width, height, tl, tr, bl);
    final dTop = sqrt(_distSq(tl, tr));
    final dLeft = sqrt(_distSq(tl, bl));
    final rawDim = (dTop + dLeft) / (2.0 * moduleSize) + 7.0;
    final primaryVersion = ((rawDim - 17.0) / 4.0).round().clamp(1, 40);

    // Build ordered candidate versions around the geometric estimate.
    final versions = <int>[primaryVersion];
    if (primaryVersion > 1) versions.add(primaryVersion - 1);
    if (primaryVersion < 40) versions.add(primaryVersion + 1);

    final triedVersions = <int>{};
    for (var idx = 0; idx < versions.length; idx++) {
      final version = versions[idx];
      if (!triedVersions.add(version)) continue;

      final dim = version * 4 + 17;
      _Point? alignment;
      if (version >= 2) {
        final ratio = (dim - 10.0) / (dim - 7.0);
        final estX = tl.x + (tr.x - tl.x) * ratio + (bl.x - tl.x) * ratio;
        final estY = tl.y + (tr.y - tl.y) * ratio + (bl.y - tl.y) * ratio;
        final searchRadius = max(moduleSize * 4.5, max(dTop, dLeft) * 0.16);
        alignment = _findAlignmentPattern(
          binary,
          width,
          height,
          estX,
          estY,
          searchRadius,
          moduleSize,
        );
      }

      // Try projective homography using alignment pattern (if found), and
      // fall back to affine 4th corner if needed.
      final transforms = <_PerspectiveTransform>[
        if (alignment != null)
          _PerspectiveTransform.quadToQuad(
            3.5,
            3.5,
            dim - 3.5,
            3.5,
            dim - 6.5,
            dim - 6.5,
            3.5,
            dim - 3.5,
            tl.x,
            tl.y,
            tr.x,
            tr.y,
            alignment.x,
            alignment.y,
            bl.x,
            bl.y,
          ),
        _PerspectiveTransform.quadToQuad(
          3.5,
          3.5,
          dim - 3.5,
          3.5,
          dim - 3.5,
          dim - 3.5,
          3.5,
          dim - 3.5,
          tl.x,
          tl.y,
          tr.x,
          tr.y,
          tr.x + bl.x - tl.x,
          tr.y + bl.y - tl.y,
          bl.x,
          bl.y,
        ),
      ];

      for (final transform in transforms) {
        final grid = _sampleGrid(binary, width, height, dim, transform);
        if (grid == null) continue;

        // For version >= 7, cross-check BCH(18, 6) version info bits; if they
        // reveal a nearby version we haven't tried yet, queue it.
        if (version >= 7) {
          final bchVersion = _readVersionInfo(grid, dim);
          if (bchVersion != null &&
              bchVersion != version &&
              (bchVersion - primaryVersion).abs() <= 3 &&
              !triedVersions.contains(bchVersion)) {
            versions.add(bchVersion);
          }
        }

        final decoded = decodeMatrix(grid, dim);
        if (decoded != null) return decoded;
      }
    }
    return null;
  }

  /// Refines the module size by measuring finder widths along TL->TR and
  /// TL->BL, blended with the cross-checked finder module sizes.
  static double _estimateModuleSize(
    Uint8List binary,
    int width,
    int height,
    _FinderCandidate tl,
    _FinderCandidate tr,
    _FinderCandidate bl,
  ) {
    final avgFinder = (tl.moduleSize + tr.moduleSize + bl.moduleSize) / 3.0;
    final s1 = _sizeOfBlackWhiteBlackRunBothWays(
      binary,
      width,
      height,
      tl.x.round(),
      tl.y.round(),
      tr.x.round(),
      tr.y.round(),
    );
    final s2 = _sizeOfBlackWhiteBlackRunBothWays(
      binary,
      width,
      height,
      tl.x.round(),
      tl.y.round(),
      bl.x.round(),
      bl.y.round(),
    );
    final lineEstimate = (s1 + s2) / 14.0;
    if (lineEstimate > avgFinder * 0.7 && lineEstimate < avgFinder * 1.35) {
      return (avgFinder + lineEstimate) / 2.0;
    }
    return avgFinder;
  }

  static double _sizeOfBlackWhiteBlackRunBothWays(
    Uint8List binary,
    int width,
    int height,
    int fromX,
    int fromY,
    int toX,
    int toY,
  ) {
    var result = _sizeOfBlackWhiteBlackRun(
      binary,
      width,
      height,
      fromX,
      fromY,
      toX,
      toY,
    );
    var otherToX = fromX - (toX - fromX);
    var scale = 1.0;
    if (otherToX < 0) {
      scale = fromX / (fromX - otherToX);
      otherToX = 0;
    } else if (otherToX >= width) {
      scale = (width - 1 - fromX) / (otherToX - fromX);
      otherToX = width - 1;
    }
    var otherToY = (fromY - (toY - fromY) * scale).round();
    scale = 1.0;
    if (otherToY < 0) {
      scale = fromY / (fromY - otherToY);
      otherToY = 0;
    } else if (otherToY >= height) {
      scale = (height - 1 - fromY) / (otherToY - fromY);
      otherToY = height - 1;
    }
    otherToX = (fromX + (otherToX - fromX) * scale).round();
    result += _sizeOfBlackWhiteBlackRun(
      binary,
      width,
      height,
      fromX,
      fromY,
      otherToX,
      otherToY,
    );
    return result - 1.0;
  }

  static double _sizeOfBlackWhiteBlackRun(
    Uint8List binary,
    int width,
    int height,
    int fromX,
    int fromY,
    int toX,
    int toY,
  ) {
    final steep = (toY - fromY).abs() > (toX - fromX).abs();
    var fx = fromX;
    var fy = fromY;
    var tx = toX;
    var ty = toY;
    if (steep) {
      var tmp = fx;
      fx = fy;
      fy = tmp;
      tmp = tx;
      tx = ty;
      ty = tmp;
    }
    final dx = (tx - fx).abs();
    final dy = (ty - fy).abs();
    var error = -dx ~/ 2;
    final xStep = fx < tx ? 1 : -1;
    final yStep = fy < ty ? 1 : -1;
    var state = 0;
    final xLimit = tx + xStep;

    for (var x = fx, y = fy; x != xLimit; x += xStep) {
      final rx = steep ? y : x;
      final ry = steep ? x : y;
      final dark =
          rx >= 0 &&
          rx < width &&
          ry >= 0 &&
          ry < height &&
          binary[ry * width + rx] == 1;
      if ((state == 1) == dark) {
        if (state == 2) {
          final ddx = x - fx;
          final ddy = y - fy;
          return sqrt(ddx * ddx + ddy * ddy);
        }
        state++;
      }
      error += dy;
      if (error > 0) {
        if (y == ty) break;
        y += yStep;
        error -= dx;
      }
    }
    final ddx = tx + xStep - fx;
    final ddy = ty - fy;
    return sqrt(ddx * ddx + ddy * ddy);
  }

  /// Searches for the bottom-right 5×5 alignment pattern (inner
  /// light-dark-light 1:1:1 ring) around ([estX], [estY]).
  static _Point? _findAlignmentPattern(
    Uint8List binary,
    int width,
    int height,
    double estX,
    double estY,
    double radius,
    double moduleSize,
  ) {
    final startX = max(0, (estX - radius).floor());
    final endX = min(width - 1, (estX + radius).ceil());
    final startY = max(0, (estY - radius).floor());
    final endY = min(height - 1, (estY + radius).ceil());
    final centerY = estY.round().clamp(startY, endY);
    final maxOffset = max(centerY - startY, endY - centerY);

    final counts = Int32List(3);
    final maxVar = moduleSize * 0.65;
    _Point? best;
    var bestDist = double.infinity;

    bool ratioOk(Int32List c) {
      if (c[0] == 0 || c[1] == 0 || c[2] == 0) return false;
      return (c[0] - moduleSize).abs() <= maxVar &&
          (c[1] - moduleSize).abs() <= maxVar &&
          (c[2] - moduleSize).abs() <= maxVar;
    }

    for (var offset = 0; offset <= maxOffset; offset++) {
      for (final dir in offset == 0 ? const [0] : const [1, -1]) {
        final y = centerY + offset * dir;
        if (y < startY || y > endY) continue;
        final rowOff = y * width;

        counts.fillRange(0, 3, 0);
        var state = 0; // 0: light, 1: dark, 2: light
        var x = startX;
        // Skip leading dark pixels so state 0 starts at a light run.
        while (x <= endX && binary[rowOff + x] == 1) {
          x++;
        }

        for (; x <= endX; x++) {
          final isDark = binary[rowOff + x] == 1;
          if (isDark) {
            if (state == 0) {
              if (counts[0] > 0) {
                state = 1;
                counts[1] = 1;
              }
            } else if (state == 1) {
              counts[1]++;
            } else {
              // state == 2 (light) -> dark border of alignment pattern!
              if (ratioOk(counts)) {
                final cx = (x - counts[2]) - counts[1] / 2.0;
                final cy = _crossCheckAlignmentVertical(
                  binary,
                  width,
                  height,
                  y,
                  cx.floor().clamp(0, width - 1),
                  moduleSize,
                );
                if (cy != null) {
                  final dx = cx - estX;
                  final dy = cy - estY;
                  final d = dx * dx + dy * dy;
                  if (d < bestDist) {
                    bestDist = d;
                    best = _Point(cx, cy);
                  }
                }
              }
              counts[0] = counts[2];
              counts[1] = 1;
              counts[2] = 0;
              state = 1;
            }
          } else {
            if (state == 0) {
              counts[0]++;
            } else if (state == 1) {
              state = 2;
              counts[2] = 1;
            } else {
              counts[2]++;
            }
          }
        }
        if (best != null && offset > moduleSize * 2) return best;
      }
    }
    return best;
  }

  static double? _crossCheckAlignmentVertical(
    Uint8List binary,
    int width,
    int height,
    int startRow,
    int col,
    double moduleSize,
  ) {
    final maxRun = (moduleSize * 2.2).ceil() + 1;
    final counts = Int32List(3);

    var y = startRow;
    while (y >= 0 && binary[y * width + col] == 1 && counts[1] <= maxRun) {
      counts[1]++;
      y--;
    }
    if (y < 0 || counts[1] > maxRun) return null;
    while (y >= 0 && binary[y * width + col] == 0 && counts[0] <= maxRun) {
      counts[0]++;
      y--;
    }
    if (y < 0 || counts[0] == 0 || counts[0] > maxRun) return null;
    // Outer top border of alignment pattern must be dark.
    if (binary[y * width + col] != 1) return null;

    y = startRow + 1;
    while (y < height && binary[y * width + col] == 1 && counts[1] <= maxRun) {
      counts[1]++;
      y++;
    }
    if (y >= height || counts[1] > maxRun) return null;
    while (y < height && binary[y * width + col] == 0 && counts[2] <= maxRun) {
      counts[2]++;
      y++;
    }
    if (y >= height || counts[2] == 0 || counts[2] > maxRun) return null;
    // Outer bottom border of alignment pattern must be dark.
    if (binary[y * width + col] != 1) return null;

    final maxVar = moduleSize * 0.65;
    if ((counts[0] - moduleSize).abs() > maxVar ||
        (counts[1] - moduleSize).abs() > maxVar ||
        (counts[2] - moduleSize).abs() > maxVar) {
      return null;
    }
    return (y - counts[2]) - counts[1] / 2.0;
  }

  static Uint8List? _sampleGrid(
    Uint8List binary,
    int width,
    int height,
    int dim,
    _PerspectiveTransform transform,
  ) {
    final grid = Uint8List(dim * dim);
    var outOfBounds = 0;

    for (var y = 0; y < dim; y++) {
      final v = y + 0.5;
      final rowOff = y * dim;
      for (var x = 0; x < dim; x++) {
        final u = x + 0.5;
        final denom = transform.a13 * u + transform.a23 * v + transform.a33;
        if (denom.abs() < 1e-9) return null;
        final px =
            ((transform.a11 * u + transform.a21 * v + transform.a31) / denom)
                .floor();
        final py =
            ((transform.a12 * u + transform.a22 * v + transform.a32) / denom)
                .floor();
        if (px < 0 || px >= width || py < 0 || py >= height) {
          outOfBounds++;
          if (outOfBounds > dim) return null;
          grid[rowOff + x] = 0;
        } else {
          grid[rowOff + x] = binary[py * width + px];
        }
      }
    }
    return grid;
  }

  /* ------------------------------------------------------------------------ */
  /* Format & Version Information (BCH(15, 5) and BCH(18, 6))                 */
  /* ------------------------------------------------------------------------ */

  static ({QrErrorCorrection errorCorrection, int mask})? _readFormatInfo(
    Uint8List modules,
    int size,
  ) {
    var copyA = 0;
    for (var i = 0; i <= 5; i++) {
      copyA |= modules[i * size + 8] << i;
    }
    copyA |= modules[7 * size + 8] << 6;
    copyA |= modules[8 * size + 8] << 7;
    copyA |= modules[8 * size + 7] << 8;
    for (var i = 9; i < 15; i++) {
      copyA |= modules[8 * size + (14 - i)] << i;
    }

    var copyB = 0;
    for (var i = 0; i < 8; i++) {
      copyB |= modules[8 * size + (size - 1 - i)] << i;
    }
    for (var i = 8; i < 15; i++) {
      copyB |= modules[(size - 15 + i) * size + 8] << i;
    }

    var bestDist = 4;
    QrErrorCorrection? bestEcl;
    var bestMask = 0;

    for (final entry in _formatTable) {
      final dA = _popcount(copyA ^ entry.bits);
      final dB = _popcount(copyB ^ entry.bits);
      final d = dA < dB ? dA : dB;
      if (d < bestDist) {
        bestDist = d;
        bestEcl = entry.ecl;
        bestMask = entry.mask;
        if (bestDist == 0) break;
      }
    }
    if (bestEcl == null) return null;
    return (errorCorrection: bestEcl, mask: bestMask);
  }

  static int? _readVersionInfo(Uint8List modules, int size) {
    var copyA = 0;
    var copyB = 0;
    for (var i = 0; i < 18; i++) {
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      copyA |= modules[b * size + a] << i;
      copyB |= modules[a * size + b] << i;
    }

    var bestDist = 4;
    int? bestVersion;
    for (var v = 7; v <= 40; v++) {
      final expected = _versionBits(v);
      final dA = _popcount(copyA ^ expected);
      final dB = _popcount(copyB ^ expected);
      final d = dA < dB ? dA : dB;
      if (d < bestDist) {
        bestDist = d;
        bestVersion = v;
        if (bestDist == 0) break;
      }
    }
    return bestVersion;
  }

  static int _popcount(int x) {
    var v = x;
    var count = 0;
    while (v != 0) {
      v &= v - 1;
      count++;
    }
    return count;
  }

  static final List<({QrErrorCorrection ecl, int mask, int bits})>
  _formatTable = [
    for (final ecl in QrErrorCorrection.values)
      for (var mask = 0; mask < 8; mask++)
        (ecl: ecl, mask: mask, bits: _formatBits(ecl, mask)),
  ];

  static int _formatBits(QrErrorCorrection ecl, int mask) {
    final data = (ecl.formatBits << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    return ((data << 10) | rem) ^ 0x5412;
  }

  static int _versionBits(int version) {
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    return (version << 12) | rem;
  }

  /* ------------------------------------------------------------------------ */
  /* Unmasking & Zigzag Codeword Extraction                                   */
  /* ------------------------------------------------------------------------ */

  static Uint8List? _readCodewords(
    Uint8List modules,
    int size,
    int version,
    int mask,
  ) {
    final functionMask = _buildFunctionMask(size, version);
    final totalBytes = _rawDataModules(version) ~/ 8;
    final codewords = Uint8List(totalBytes);
    final totalBits = totalBytes * 8;
    var bitIndex = 0;

    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      final upward = ((right + 1) & 2) == 0;
      for (var vertical = 0; vertical < size; vertical++) {
        final y = upward ? size - 1 - vertical : vertical;
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          if (functionMask[y * size + x] == 1) continue;
          if (bitIndex >= totalBits) break;
          var bit = modules[y * size + x] & 1;
          if (_maskInverts(mask, x, y)) bit ^= 1;
          codewords[bitIndex >> 3] |= bit << (7 - (bitIndex & 7));
          bitIndex++;
        }
      }
    }
    return bitIndex == totalBits ? codewords : null;
  }

  static Uint8List _buildFunctionMask(int size, int version) {
    final mask = Uint8List(size * size);
    void markRect(int x0, int y0, int x1, int y1) {
      for (var y = y0; y <= y1; y++) {
        final row = y * size;
        for (var x = x0; x <= x1; x++) {
          mask[row + x] = 1;
        }
      }
    }

    // Timing patterns.
    for (var i = 0; i < size; i++) {
      mask[6 * size + i] = 1;
      mask[i * size + 6] = 1;
    }

    // Finders, separators, format areas, and the dark module.
    markRect(0, 0, 8, 8);
    markRect(size - 8, 0, size - 1, 8);
    markRect(0, size - 8, 8, size - 1);

    // Alignment patterns.
    final positions = _alignmentPositions(version);
    final last = positions.length - 1;
    for (var i = 0; i <= last; i++) {
      for (var j = 0; j <= last; j++) {
        if ((i == 0 && j == 0) ||
            (i == 0 && j == last) ||
            (i == last && j == 0)) {
          continue;
        }
        final cx = positions[i];
        final cy = positions[j];
        markRect(cx - 2, cy - 2, cx + 2, cy + 2);
      }
    }

    // Version information (versions 7..40).
    if (version >= 7) {
      markRect(size - 11, 0, size - 9, 5);
      markRect(0, size - 11, 5, size - 9);
    }

    return mask;
  }

  static List<int> _alignmentPositions(int version) {
    if (version == 1) return const [];
    final count = version ~/ 7 + 2;
    final step = (version * 8 + count * 3 + 5) ~/ (count * 4 - 4) * 2;
    final result = [6];
    for (var pos = version * 4 + 10; result.length < count;) {
      result.insert(1, pos);
      pos -= step;
    }
    return result;
  }

  static bool _maskInverts(int mask, int x, int y) => switch (mask) {
    0 => (x + y).isEven,
    1 => y.isEven,
    2 => x % 3 == 0,
    3 => (x + y) % 3 == 0,
    4 => (x ~/ 3 + y ~/ 2).isEven,
    5 => x * y % 2 + x * y % 3 == 0,
    6 => (x * y % 2 + x * y % 3).isEven,
    7 => ((x + y) % 2 + x * y % 3).isEven,
    _ => false,
  };

  static int _rawDataModules(int version) {
    var result = (16 * version + 128) * version + 64;
    if (version >= 2) {
      final alignments = version ~/ 7 + 2;
      result -= (25 * alignments - 10) * alignments - 55;
      if (version >= 7) result -= 36;
    }
    return result;
  }

  /* ------------------------------------------------------------------------ */
  /* De-interleaving & GF(2^8) Reed-Solomon Error Correction                  */
  /* ------------------------------------------------------------------------ */

  static Uint8List? _deinterleaveAndCorrect(
    Uint8List codewords,
    int version,
    QrErrorCorrection ecl,
  ) {
    final blockCount = _blocks[ecl.index][version];
    final eccLength = _eccPerBlock[ecl.index][version];
    final total = codewords.length;
    final shortBlocks = blockCount - total % blockCount;
    final shortLength = total ~/ blockCount;
    final shortDataLen = shortLength - eccLength;

    final blocks = [
      for (var i = 0; i < blockCount; i++)
        Uint8List(shortLength + (i < shortBlocks ? 0 : 1)),
    ];

    var src = 0;
    // Data codewords shared by all blocks.
    for (var i = 0; i < shortDataLen; i++) {
      for (var j = 0; j < blockCount; j++) {
        blocks[j][i] = codewords[src++];
      }
    }
    // Extra data codeword for long blocks.
    for (var j = shortBlocks; j < blockCount; j++) {
      blocks[j][shortDataLen] = codewords[src++];
    }
    // EC codewords.
    for (var i = 0; i < eccLength; i++) {
      for (var j = 0; j < blockCount; j++) {
        final dstIdx = (j < shortBlocks ? shortDataLen : shortDataLen + 1) + i;
        blocks[j][dstIdx] = codewords[src++];
      }
    }

    final totalData = total - blockCount * eccLength;
    final result = Uint8List(totalData);
    var outOffset = 0;

    for (var j = 0; j < blockCount; j++) {
      final block = blocks[j];
      if (!_reedSolomonCorrect(block, eccLength)) return null;
      final dataLen = block.length - eccLength;
      result.setRange(outOffset, outOffset + dataLen, block);
      outOffset += dataLen;
    }
    return result;
  }

  /// Corrects [block] in-place using GF(2⁸) (polynomial 0x11D) Reed-Solomon
  /// with [eccLength] parity bytes and first consecutive root α⁰.
  /// Returns `false` if errors exceed correction capacity or fail syndrome
  /// re-verification.
  static bool _reedSolomonCorrect(Uint8List block, int eccLength) {
    final n = block.length;
    final syndromes = Uint8List(eccLength);
    var hasError = false;

    for (var i = 0; i < eccLength; i++) {
      final alphaI = _gfExp[i];
      var s = 0;
      for (var k = 0; k < n; k++) {
        s = _gfMul(s, alphaI) ^ block[k];
      }
      syndromes[i] = s;
      if (s != 0) hasError = true;
    }
    if (!hasError) return true;

    // Berlekamp-Massey: error locator Λ(x) = 1 + Λ_1 x + ... + Λ_L x^L.
    final c = <int>[1];
    var b = <int>[1];
    var l = 0;
    var m = 1;
    var bb = 1;

    for (var k = 0; k < eccLength; k++) {
      var d = syndromes[k];
      for (var i = 1; i <= l; i++) {
        if (i < c.length) {
          d ^= _gfMul(c[i], syndromes[k - i]);
        }
      }
      if (d == 0) {
        m++;
      } else {
        final t = List<int>.of(c);
        final coef = _gfMul(d, _gfInv(bb));
        final needed = b.length + m;
        while (c.length < needed) {
          c.add(0);
        }
        for (var i = 0; i < b.length; i++) {
          c[i + m] ^= _gfMul(coef, b[i]);
        }
        if (2 * l <= k) {
          l = k + 1 - l;
          b = t;
          bb = d;
          m = 1;
        } else {
          m++;
        }
      }
    }

    while (c.length > 1 && c.last == 0) {
      c.removeLast();
    }
    final errCount = c.length - 1;
    if (errCount != l || errCount > eccLength ~/ 2) return false;

    // Chien search for roots X_j^{-1} of Λ(x).
    final errPositions = <int>[];
    for (var pos = 0; pos < n; pos++) {
      final xInv = pos == 0 ? 1 : _gfExp[255 - pos];
      var eval = 0;
      var xPow = 1;
      for (var i = 0; i < c.length; i++) {
        eval ^= _gfMul(c[i], xPow);
        xPow = _gfMul(xPow, xInv);
      }
      if (eval == 0) {
        errPositions.add(pos);
      }
    }
    if (errPositions.length != errCount) return false;

    // Error evaluator polynomial Ω(x) = S(x) * Λ(x) mod x^eccLength.
    final omega = Uint8List(errCount);
    for (var i = 0; i < errCount; i++) {
      var acc = 0;
      for (var j = 0; j <= i; j++) {
        if (j < c.length) {
          acc ^= _gfMul(syndromes[i - j], c[j]);
        }
      }
      omega[i] = acc;
    }

    // Forney algorithm (fcr = 0): e_j = X_j * Ω(X_j^{-1}) / Λ'(X_j^{-1}).
    for (final pos in errPositions) {
      final x = _gfExp[pos];
      final xInv = pos == 0 ? 1 : _gfExp[255 - pos];

      var num = 0;
      var xPow = 1;
      for (var i = 0; i < omega.length; i++) {
        num ^= _gfMul(omega[i], xPow);
        xPow = _gfMul(xPow, xInv);
      }

      // Formal derivative Λ'(x) in GF(2^8): odd-index terms only.
      var den = 0;
      final xInvSq = _gfMul(xInv, xInv);
      var pow = 1;
      for (var i = 1; i < c.length; i += 2) {
        den ^= _gfMul(c[i], pow);
        pow = _gfMul(pow, xInvSq);
      }
      if (den == 0) return false;

      final magnitude = _gfMul(x, _gfMul(num, _gfInv(den)));
      block[n - 1 - pos] ^= magnitude;
    }

    // Re-verify all syndromes are zero.
    for (var i = 0; i < eccLength; i++) {
      final alphaI = _gfExp[i];
      var s = 0;
      for (var k = 0; k < n; k++) {
        s = _gfMul(s, alphaI) ^ block[k];
      }
      if (s != 0) return false;
    }
    return true;
  }

  static final ({Uint8List exp, Uint8List log}) _gfTables = () {
    final exp = Uint8List(512);
    final log = Uint8List(256);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      exp[i] = x;
      log[x] = i;
      x <<= 1;
      if ((x & 0x100) != 0) x ^= 0x11D;
    }
    for (var i = 255; i < 512; i++) {
      exp[i] = exp[i - 255];
    }
    return (exp: exp, log: log);
  }();

  static Uint8List get _gfExp => _gfTables.exp;
  static Uint8List get _gfLog => _gfTables.log;

  static int _gfMul(int a, int b) =>
      (a == 0 || b == 0) ? 0 : _gfExp[_gfLog[a] + _gfLog[b]];

  static int _gfInv(int a) => _gfExp[255 - _gfLog[a]];

  /// ISO/IEC 18004:2015 Table 9 — EC codewords per block by level & version.
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

  /// ISO/IEC 18004:2015 Table 9 — number of EC blocks by level & version.
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

  /* ------------------------------------------------------------------------ */
  /* Bit-stream Decoding (Numeric, Alphanumeric, Byte, ECI)                   */
  /* ------------------------------------------------------------------------ */

  static const _alphanumericChars =
      r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

  static String? _decodeBitStream(Uint8List data, int version) {
    final reader = _BitReader(data);
    final out = StringBuffer();
    int? eci;

    while (reader.remaining >= 4) {
      final mode = reader.readBits(4);
      if (mode == 0x0) break; // Terminator.

      switch (mode) {
        case 0x1: // Numeric
          final countBits = version <= 9 ? 10 : (version <= 26 ? 12 : 14);
          if (reader.remaining < countBits) return null;
          var count = reader.readBits(countBits);
          while (count >= 3) {
            if (reader.remaining < 10) return null;
            final value = reader.readBits(10);
            if (value >= 1000) return null;
            out.write(value.toString().padLeft(3, '0'));
            count -= 3;
          }
          if (count == 2) {
            if (reader.remaining < 7) return null;
            final value = reader.readBits(7);
            if (value >= 100) return null;
            out.write(value.toString().padLeft(2, '0'));
          } else if (count == 1) {
            if (reader.remaining < 4) return null;
            final value = reader.readBits(4);
            if (value >= 10) return null;
            out.write(value);
          }

        case 0x2: // Alphanumeric
          final countBits = version <= 9 ? 9 : (version <= 26 ? 11 : 13);
          if (reader.remaining < countBits) return null;
          var count = reader.readBits(countBits);
          while (count >= 2) {
            if (reader.remaining < 11) return null;
            final value = reader.readBits(11);
            final c1 = value ~/ 45;
            final c2 = value % 45;
            if (c1 >= 45) return null;
            out
              ..write(_alphanumericChars[c1])
              ..write(_alphanumericChars[c2]);
            count -= 2;
          }
          if (count == 1) {
            if (reader.remaining < 6) return null;
            final value = reader.readBits(6);
            if (value >= 45) return null;
            out.write(_alphanumericChars[value]);
          }

        case 0x4: // Byte
          final countBits = version <= 9 ? 8 : 16;
          if (reader.remaining < countBits) return null;
          final count = reader.readBits(countBits);
          if (reader.remaining < count * 8) return null;
          final bytes = Uint8List(count);
          for (var i = 0; i < count; i++) {
            bytes[i] = reader.readBits(8);
          }
          if (eci == 3) {
            out.write(latin1.decode(bytes));
          } else {
            try {
              out.write(utf8.decode(bytes));
            } on FormatException {
              out.write(latin1.decode(bytes));
            }
          }

        case 0x7: // ECI
          if (reader.remaining < 8) return null;
          final first = reader.readBits(8);
          if ((first & 0x80) == 0) {
            eci = first & 0x7F;
          } else if ((first & 0xC0) == 0x80) {
            if (reader.remaining < 8) return null;
            eci = ((first & 0x3F) << 8) | reader.readBits(8);
          } else if ((first & 0xE0) == 0xC0) {
            if (reader.remaining < 16) return null;
            eci = ((first & 0x1F) << 16) | reader.readBits(16);
          } else {
            return null;
          }

        case 0x5: // FNC1 first position (no payload bits)
          break;

        case 0x9: // FNC1 second position (8-bit application indicator)
          if (reader.remaining < 8) return null;
          reader.readBits(8);

        default:
          return null;
      }
    }

    return out.toString();
  }
}

final class _Point {
  const new(this.x, this.y);
  final double x;
  final double y;
}

final class _FinderCandidate {
  new(this.x, this.y, this.moduleSize);

  double x;
  double y;
  double moduleSize;
  int count = 1;

  bool matches(double cx, double cy, double modSize) {
    final posTol = max(2, max(moduleSize, modSize) * 1.5);
    if ((cx - x).abs() > posTol || (cy - y).abs() > posTol) return false;
    final diff = (modSize - moduleSize).abs();
    return diff <= 1.0 || diff <= moduleSize * 0.5;
  }

  void combine(double cx, double cy, double modSize) {
    final nextCount = count + 1;
    x = (count * x + cx) / nextCount;
    y = (count * y + cy) / nextCount;
    moduleSize = (count * moduleSize + modSize) / nextCount;
    count = nextCount;
  }
}

final class _FinderTriple {
  const new({
    required this.tl,
    required this.tr,
    required this.bl,
    required this.score,
  });

  final _FinderCandidate tl;
  final _FinderCandidate tr;
  final _FinderCandidate bl;
  final double score;
}

/// 3×3 projective homography mapping module coordinates `(u, v)` to image
/// pixel coordinates `(x, y)`.
final class _PerspectiveTransform {
  const new(
    this.a11,
    this.a21,
    this.a31,
    this.a12,
    this.a22,
    this.a32,
    this.a13,
    this.a23,
    this.a33,
  );

  factory quadToQuad(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    double x0p,
    double y0p,
    double x1p,
    double y1p,
    double x2p,
    double y2p,
    double x3p,
    double y3p,
  ) {
    final qToS = _PerspectiveTransform.quadToSquare(
      x0,
      y0,
      x1,
      y1,
      x2,
      y2,
      x3,
      y3,
    );
    final sToQ = _PerspectiveTransform.squareToQuad(
      x0p,
      y0p,
      x1p,
      y1p,
      x2p,
      y2p,
      x3p,
      y3p,
    );
    return sToQ._times(qToS);
  }

  factory squareToQuad(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    final dx3 = x0 - x1 + x2 - x3;
    final dy3 = y0 - y1 + y2 - y3;
    if (dx3 == 0 && dy3 == 0) {
      return _PerspectiveTransform(
        x1 - x0,
        x2 - x1,
        x0,
        y1 - y0,
        y2 - y1,
        y0,
        0,
        0,
        1,
      );
    }
    final dx1 = x1 - x2;
    final dx2 = x3 - x2;
    final dy1 = y1 - y2;
    final dy2 = y3 - y2;
    final denom = dx1 * dy2 - dx2 * dy1;
    final a13 = (dx3 * dy2 - dx2 * dy3) / denom;
    final a23 = (dx1 * dy3 - dx3 * dy1) / denom;
    return _PerspectiveTransform(
      x1 - x0 + a13 * x1,
      x3 - x0 + a23 * x3,
      x0,
      y1 - y0 + a13 * y1,
      y3 - y0 + a23 * y3,
      y0,
      a13,
      a23,
      1,
    );
  }

  factory quadToSquare(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => _PerspectiveTransform.squareToQuad(
    x0,
    y0,
    x1,
    y1,
    x2,
    y2,
    x3,
    y3,
  )._buildAdjoint();

  final double a11;
  final double a21;
  final double a31;
  final double a12;
  final double a22;
  final double a32;
  final double a13;
  final double a23;
  final double a33;

  _PerspectiveTransform _buildAdjoint() => _PerspectiveTransform(
    a22 * a33 - a23 * a32,
    a23 * a31 - a21 * a33,
    a21 * a32 - a22 * a31,
    a13 * a32 - a12 * a33,
    a11 * a33 - a13 * a31,
    a12 * a31 - a11 * a32,
    a12 * a23 - a13 * a22,
    a13 * a21 - a11 * a23,
    a11 * a22 - a12 * a21,
  );

  _PerspectiveTransform _times(_PerspectiveTransform o) =>
      _PerspectiveTransform(
        a11 * o.a11 + a21 * o.a12 + a31 * o.a13,
        a11 * o.a21 + a21 * o.a22 + a31 * o.a23,
        a11 * o.a31 + a21 * o.a32 + a31 * o.a33,
        a12 * o.a11 + a22 * o.a12 + a32 * o.a13,
        a12 * o.a21 + a22 * o.a22 + a32 * o.a23,
        a12 * o.a31 + a22 * o.a32 + a32 * o.a33,
        a13 * o.a11 + a23 * o.a12 + a33 * o.a13,
        a13 * o.a21 + a23 * o.a22 + a33 * o.a23,
        a13 * o.a31 + a23 * o.a32 + a33 * o.a33,
      );
}

final class _BitReader {
  new(this._bytes);

  final Uint8List _bytes;
  int _bitOffset = 0;

  int get remaining => _bytes.length * 8 - _bitOffset;

  int readBits(int count) {
    var result = 0;
    for (var i = 0; i < count; i++) {
      final byteIdx = _bitOffset >> 3;
      final shift = 7 - (_bitOffset & 7);
      result = (result << 1) | ((_bytes[byteIdx] >> shift) & 1);
      _bitOffset++;
    }
    return result;
  }
}
