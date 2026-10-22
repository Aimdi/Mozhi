import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:tesseract_ocr/src/engine/ocr_layout.dart';

/// The native engine failed (it could not be loaded, a language could not
/// be loaded, or recognition failed).
final class TesseractEngineException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'TesseractEngineException($message)';
}

/// Raw pixels for [OcrEngine.recognize].
@immutable
final class OcrImage {
  /// [bytesPerPixel] is 1 (gray), 3 (RGB) or 4 (RGBA with premultiplied
  /// alpha, as `dart:ui`'s `ImageByteFormat.rawRgba` gives it; transparent
  /// pixels count as white). [bytesPerLine] defaults to
  /// `width * bytesPerPixel` (no padding).
  new(
    this.pixels, {
    required this.width,
    required this.height,
    this.bytesPerPixel = 4,
    int? bytesPerLine,
  }) : bytesPerLine = bytesPerLine ?? width * bytesPerPixel {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Invalid image size ${width}x$height');
    }
    if (bytesPerPixel != 1 && bytesPerPixel != 3 && bytesPerPixel != 4) {
      throw ArgumentError.value(
        bytesPerPixel,
        'bytesPerPixel',
        'Not 1, 3 or 4',
      );
    }
    if (this.bytesPerLine < width * bytesPerPixel) {
      throw ArgumentError.value(
        this.bytesPerLine,
        'bytesPerLine',
        'Shorter than a row',
      );
    }
    if (pixels.lengthInBytes <
        this.bytesPerLine * (height - 1) + width * bytesPerPixel) {
      throw ArgumentError.value(
        pixels.lengthInBytes,
        'pixels',
        'Too few bytes for ${width}x$height',
      );
    }
  }

  final Uint8List pixels;
  final int width;
  final int height;
  final int bytesPerPixel;
  final int bytesPerLine;

  @override
  String toString() => 'OcrImage(${width}x$height, $bytesPerPixel B/px)';
}

/// What [OcrEngine.recognize] found.
@immutable
final class OcrResult {
  const new({required this.text, this.meanConfidence = 0, this.layout});

  /// The recognised text: lines separated by `\n`, paragraphs by an empty
  /// line (trimmed; empty when there is none).
  final String text;

  /// Tesseract's mean word confidence, 0 to 100.
  final int meanConfidence;

  /// Where the text is in the image (blocks, paragraphs, lines and words
  /// with their boxes), when it was asked for (`layout: true`).
  final OcrLayout? layout;

  @override
  bool operator ==(Object other) =>
      other is OcrResult &&
      other.text == text &&
      other.meanConfidence == meanConfidence &&
      other.layout == layout;

  @override
  int get hashCode => Object.hash(text, meanConfidence, layout);

  @override
  String toString() =>
      'OcrResult(${text.length} chars, $meanConfidence%'
      '${layout == null ? '' : ', ${layout!.paragraphs.length} paragraphs'})';
}

/// The OCR engine: Tesseract in a background isolate (see
/// `createTesseractEngine`), or a fake in tests.
abstract interface class OcrEngine {
  /// Recognises the text in [image] with [languages] (Tesseract codes,
  /// main language first), whose `<code>.traineddata` files are in
  /// [dataPath]. With [layout], the result also says where the text is
  /// ([OcrResult.layout], words included). Throws
  /// [TesseractEngineException] on failure.
  Future<OcrResult> recognize(
    OcrImage image, {
    required String dataPath,
    required List<String> languages,
    bool layout = false,
  });

  /// Unloads every loaded language (call after language data changed on
  /// disk; the next [recognize] loads it again).
  Future<void> release();

  /// Stops the engine; a later [recognize] starts it again.
  Future<void> dispose();
}
