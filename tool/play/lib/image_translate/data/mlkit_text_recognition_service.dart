import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mozhi/image_translate/data/image_encoder.dart';
import 'package:mozhi/image_translate/data/rgba_image_decoder.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:translation_repository/translation_repository.dart';

// Play variant only (tool/play_prepare.sh copies it to
// lib/image_translate/data/): the only app file, with the Play bindings in
// lib/platform/mlkit_bindings.dart, that imports ML Kit's text recognition.
// The default (Google-free) build has neither, so it must not be exported
// from data.dart or imported anywhere else.

/// Creates a recognizer for a script (overridable for tests).
typedef TextRecognizerFactory = TextRecognizer Function(
  TextRecognitionScript script,
);

/// Writes [bytes] (an encoded image) to a new private temporary file and
/// returns its path (overridable for tests).
typedef TemporaryImageWriter = Future<String> Function(Uint8List bytes);

/// [TextRecognitionService] backed by Google ML Kit (Android and iOS only).
///
/// Implements [TextRecognitionLayout] so the image screen can draw the
/// translated photo overlay (with bounding boxes, line tilt angles and
/// sampled colours) in the Play variant too.
///
/// ML Kit reads files: an image without a path (a screenshot, a still of
/// the live camera) is written to the app's private cache for the reading
/// and deleted right after. It goes into the screenshots' folder
/// (`<cache>/screen_translate`), which the app empties when it starts
/// (`ScreenCaptures.sweepLeftovers`), so a copy left by a process that died
/// while reading is deleted too.
class MlKitTextRecognitionService
    implements TextRecognitionService, TextRecognitionLayout {
  new({
    TextRecognizerFactory? recognizerFactory,
    TemporaryImageWriter? temporaryImageWriter,
    this._decoder,
    this._platform,
    this._isWeb = kIsWeb,
  }) : _factory = recognizerFactory ?? _defaultFactory,
       _writeTemporary = temporaryImageWriter ?? _defaultTemporaryImageWriter;

  static TextRecognizer _defaultFactory(TextRecognitionScript script) =>
      TextRecognizer(script: script);

  // coverage:ignore-start
  static Future<String> _defaultTemporaryImageWriter(Uint8List bytes) async {
    final cache = await getTemporaryDirectory();
    final folder = Directory('${cache.path}/screen_translate');
    await folder.create(recursive: true);
    final file = File(
      '${folder.path}/mlkit_${DateTime.now().microsecondsSinceEpoch}.img',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
  // coverage:ignore-end

  final TextRecognizerFactory _factory;
  final TemporaryImageWriter _writeTemporary;
  final RgbaImageDecoder? _decoder;
  final TargetPlatform? _platform;
  final bool _isWeb;

  @override
  bool get isSupported {
    if (_isWeb) return false;
    final platform = _platform ?? defaultTargetPlatform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  @override
  Future<String> recognize(
    PickedImage image, {
    required Language source,
  }) async {
    final recognized = await _process(image, source: source);
    return recognized.text.trim();
  }

  @override
  Future<TextWithConfidence> recognizeLayout(
    PickedImage image, {
    required Language source,
  }) async {
    final recognized = await _process(image, source: source);
    final decoded = await _decodeForLayout(image.bytes);
    final layout = decoded == null
        ? null
        : textLayoutOf(
            recognized,
            width: decoded.width,
            height: decoded.height,
            sample: decoded.sample,
          );
    final text = layout != null && !layout.isEmpty
        ? layout.text
        : recognized.text.trim();
    return TextWithConfidence(
      text,
      confidence: _meanConfidence(recognized),
      layout: layout,
    );
  }

  Future<RecognizedText> _process(
    PickedImage image, {
    required Language source,
  }) async {
    if (!isSupported) {
      throw const ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
      );
    }
    String? temporary;
    final String path;
    try {
      path = image.path ?? (temporary = await _writeTemporary(image.bytes));
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
        cause: error,
      );
    }
    final recognizer = _factory(scriptFor(source));
    try {
      return await recognizer.processImage(InputImage.fromFilePath(path));
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
        cause: error,
      );
    } finally {
      try {
        await recognizer.close();
      } on Object {
        // Closing is best effort.
      }
      if (temporary != null) await _delete(temporary);
    }
  }

  /// Decodes upright image dimensions and a small RGBA copy for colour
  /// sampling; returns null if decoding fails (plain-text fallback).
  Future<({int width, int height, RgbaImage sample})?> _decodeForLayout(
    Uint8List bytes,
  ) async {
    final injected = _decoder;
    if (injected != null) {
      try {
        final rgba = await injected.decode(bytes);
        if (rgba.width <= 0 || rgba.height <= 0) return null;
        return (width: rgba.width, height: rgba.height, sample: rgba);
      } on Object {
        return null;
      }
    }
    ui.Codec? codec;
    ui.Image? frame;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      var fullWidth = 0;
      var fullHeight = 0;
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) {
          fullWidth = width;
          fullHeight = height;
          return UiImageEncoder.targetSize(width, height, _sampleMaxSide);
        },
      );
      frame = (await codec.getNextFrame()).image;
      final data = await frame.toByteData();
      if (data == null || fullWidth <= 0 || fullHeight <= 0) return null;
      final sample = RgbaImage(
        pixels: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: frame.width,
        height: frame.height,
      );
      return (width: fullWidth, height: fullHeight, sample: sample);
    } on Object {
      return null;
    } finally {
      frame?.dispose();
      codec?.dispose();
    }
  }

  /// Converts ML Kit's [recognized] blocks into a [TextLayout] in the image's
  /// upright pixel coordinate space ([width] x [height]). Returns null when no
  /// usable blocks remain or dimensions are invalid.
  @visibleForTesting
  static TextLayout? textLayoutOf(
    RecognizedText recognized, {
    required int width,
    required int height,
    RgbaImage? sample,
  }) {
    if (width <= 0 || height <= 0 || recognized.blocks.isEmpty) return null;
    final bounds = ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final paragraphs = <TextParagraph>[];
    for (final block in recognized.blocks) {
      final paragraph = _paragraphOf(
        block,
        bounds: bounds,
        width: width,
        height: height,
        sample: sample,
      );
      if (paragraph != null) paragraphs.add(paragraph);
    }
    if (paragraphs.isEmpty) return null;
    return TextLayout(width: width, height: height, paragraphs: paragraphs);
  }

  static TextParagraph? _paragraphOf(
    TextBlock block, {
    required ui.Rect bounds,
    required int width,
    required int height,
    RgbaImage? sample,
  }) {
    final lineTexts = block.lines.isEmpty
        ? [block.text]
        : [for (final line in block.lines) line.text];
    final text = TextParagraph.joinLines(lineTexts);
    if (!_letterOrDigit.hasMatch(text)) return null;

    final box = block.boundingBox.intersect(bounds);
    if (box.width <= 0 || box.height <= 0) return null;

    final confidence = _blockConfidence(block);
    if (confidence != null &&
        confidence < _speckConfidence &&
        text.runes.length <= 2) {
      return null;
    }

    final colors = sample == null
        ? null
        : _sampleColors(sample, box, imageWidth: width, imageHeight: height);

    return TextParagraph(
      text: text,
      box: box,
      lineCount: block.lines.isEmpty ? 1 : block.lines.length,
      alignment: _blockAlignment(block, box),
      isRightToLeft: _rtlScript.hasMatch(text),
      background: colors?.background,
      foreground: colors?.foreground,
      confidence: confidence,
      angle: _blockAngle(block),
    );
  }

  static int? _meanConfidence(RecognizedText recognized) {
    var sum = 0.0;
    var count = 0;
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final value = line.confidence;
        if (value != null && value.isFinite) {
          sum += value.clamp(0.0, 1.0);
          count++;
        }
      }
    }
    return count == 0 ? null : (sum / count * 100).round().clamp(0, 100);
  }

  static int? _blockConfidence(TextBlock block) {
    var sum = 0.0;
    var count = 0;
    for (final line in block.lines) {
      final value = line.confidence;
      if (value != null && value.isFinite) {
        sum += value.clamp(0.0, 1.0);
        count++;
      }
    }
    return count == 0 ? null : (sum / count * 100).round().clamp(0, 100);
  }

  /// Clockwise tilt in degrees for [block]: median of [TextLine.angle] when
  /// reported (Android), falling back to the top edge of
  /// [TextBlock.cornerPoints] (iOS). Small angles (< 1.5°) snap to 0; extreme
  /// angles clamp to ±45°.
  static double _blockAngle(TextBlock block) {
    final angles = <double>[];
    for (final line in block.lines) {
      final angle = line.angle;
      if (angle != null && angle.isFinite && angle.abs() <= _maxTiltDegrees) {
        angles.add(angle);
      }
    }
    double raw;
    if (angles.isNotEmpty) {
      angles.sort();
      final mid = angles.length ~/ 2;
      raw = angles.length.isOdd
          ? angles[mid]
          : (angles[mid - 1] + angles[mid]) / 2;
    } else if (block.cornerPoints.length >= 2) {
      final p0 = block.cornerPoints[0];
      final p1 = block.cornerPoints[1];
      final dx = p1.x - p0.x;
      final dy = p1.y - p0.y;
      if (dx * dx + dy * dy < _minEdgeSquared) return 0;
      raw = math.atan2(dy, dx) * 180 / math.pi;
      if (raw.abs() > _maxTiltDegrees) return 0;
    } else {
      return 0;
    }
    if (raw.abs() < _minTiltDegrees) return 0;
    return raw.clamp(-_maxTiltDegrees, _maxTiltDegrees);
  }

  static TextParagraphAlignment _blockAlignment(TextBlock block, ui.Rect box) {
    if (block.lines.length < 2 || box.width <= 0) {
      return TextParagraphAlignment.unknown;
    }
    final tolerance = math.max<double>(4, box.width * 0.08);
    var leftAligned = true;
    var rightAligned = true;
    var centered = true;
    final boxCenter = box.center.dx;
    for (final line in block.lines) {
      final r = line.boundingBox;
      if ((r.left - box.left).abs() > tolerance) leftAligned = false;
      if ((box.right - r.right).abs() > tolerance) rightAligned = false;
      if ((r.center.dx - boxCenter).abs() > tolerance) centered = false;
    }
    if (leftAligned && !rightAligned) return TextParagraphAlignment.left;
    if (rightAligned && !leftAligned) return TextParagraphAlignment.right;
    if (centered && !leftAligned && !rightAligned) {
      return TextParagraphAlignment.center;
    }
    return TextParagraphAlignment.unknown;
  }

  /// Samples opaque background (perimeter ring around [box]) and foreground
  /// (interior pixels contrasting most with the background) colours from
  /// [sample].
  static ({ui.Color background, ui.Color? foreground})? _sampleColors(
    RgbaImage sample,
    ui.Rect box, {
    required int imageWidth,
    required int imageHeight,
  }) {
    if (sample.width <= 0 ||
        sample.height <= 0 ||
        sample.pixels.length < sample.width * sample.height * 4) {
      return null;
    }
    final sx = sample.width / imageWidth;
    final sy = sample.height / imageHeight;
    final left = (box.left * sx).floor().clamp(0, sample.width - 1);
    final top = (box.top * sy).floor().clamp(0, sample.height - 1);
    final right = (box.right * sx).ceil().clamp(left + 1, sample.width);
    final bottom = (box.bottom * sy).ceil().clamp(top + 1, sample.height);

    final bgR = <int>[];
    final bgG = <int>[];
    final bgB = <int>[];
    void addBg(int x, int y) {
      final offset = (y * sample.width + x) * 4;
      bgR.add(sample.pixels[offset]);
      bgG.add(sample.pixels[offset + 1]);
      bgB.add(sample.pixels[offset + 2]);
    }

    const pad = 2;
    final topY = (top - pad).clamp(0, sample.height - 1);
    final botY = (bottom - 1 + pad).clamp(0, sample.height - 1);
    final leftX = (left - pad).clamp(0, sample.width - 1);
    final rightX = (right - 1 + pad).clamp(0, sample.width - 1);
    final xStep = math.max(1, (right - left) ~/ 24);
    final yStep = math.max(1, (bottom - top) ~/ 12);

    for (var x = left; x < right; x += xStep) {
      addBg(x, topY);
      addBg(x, botY);
    }
    for (var y = top; y < bottom; y += yStep) {
      addBg(leftX, y);
      addBg(rightX, y);
    }
    if (bgR.isEmpty) return null;

    final br = _medianInt(bgR);
    final bg = _medianInt(bgG);
    final bb = _medianInt(bgB);
    final background = ui.Color.fromARGB(255, br, bg, bb);

    final fgR = <int>[];
    final fgG = <int>[];
    final fgB = <int>[];
    final inXStep = math.max(1, (right - left) ~/ 24);
    final inYStep = math.max(1, (bottom - top) ~/ 16);
    for (var y = top; y < bottom; y += inYStep) {
      for (var x = left; x < right; x += inXStep) {
        final offset = (y * sample.width + x) * 4;
        final r = sample.pixels[offset];
        final g = sample.pixels[offset + 1];
        final b = sample.pixels[offset + 2];
        final dist = (r - br).abs() + (g - bg).abs() + (b - bb).abs();
        if (dist >= _minColorDiff) {
          fgR.add(r);
          fgG.add(g);
          fgB.add(b);
        }
      }
    }
    final foreground = fgR.isEmpty
        ? null
        : ui.Color.fromARGB(
            255,
            _medianInt(fgR),
            _medianInt(fgG),
            _medianInt(fgB),
          );
    return (background: background, foreground: foreground);
  }

  static int _medianInt(List<int> values) {
    values.sort();
    return values[values.length ~/ 2];
  }

  static Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on Object {
      // Already gone; the next start sweeps the folder otherwise.
    }
  }

  /// The ML Kit script model for [language] (Latin for auto/unknown).
  static TextRecognitionScript scriptFor(Language language) {
    final code = language.code.toLowerCase().split(RegExp('[-_]')).first;
    return switch (code) {
      'zh' || 'yue' => TextRecognitionScript.chinese,
      'ja' => TextRecognitionScript.japanese,
      'ko' => TextRecognitionScript.korean,
      'hi' ||
      'mr' ||
      'ne' ||
      'sa' ||
      'mai' ||
      'bho' ||
      'kok' => TextRecognitionScript.devanagiri,
      _ => TextRecognitionScript.latin,
    };
  }

  static const _sampleMaxSide = 1024;
  static const _minEdgeSquared = 16;
  static const _minTiltDegrees = 1.5;
  static const _maxTiltDegrees = 45.0;
  static const _speckConfidence = 30;
  static const _minColorDiff = 90;

  static final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _rtlScript = RegExp(
    r'[\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Syriac}\p{Script=Thaana}]',
    unicode: true,
  );
}
