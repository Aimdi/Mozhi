import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/data/image_encoder.dart';
import 'package:mozhi/image_translate/models/models.dart';

/// Decoded pixels: RGBA with premultiplied alpha, rows without padding.
@immutable
class RgbaImage {
  const new({required this.pixels, required this.width, required this.height});

  final Uint8List pixels;
  final int width;
  final int height;
}

/// Decodes images to raw pixels for on-device text recognition (injectable
/// for tests).
abstract interface class RgbaImageDecoder {
  /// Decodes [bytes] with the long side capped at [maxSide] (never
  /// upscaled). Throws [ImageTranslateException] (`invalidImage`) when
  /// they are not a decodable image.
  Future<RgbaImage> decode(Uint8List bytes, {int maxSide = defaultOcrMaxSide});
}

/// Long side cap for text recognition: enough for the small print of a
/// photo, without making recognition slow.
const int defaultOcrMaxSide = 2500;

/// [RgbaImageDecoder] using the engine's codecs (`dart:ui`, which also
/// applies a JPEG's EXIF orientation), so no image library is needed.
class UiRgbaImageDecoder implements RgbaImageDecoder {
  const new();

  @override
  Future<RgbaImage> decode(
    Uint8List bytes, {
    int maxSide = defaultOcrMaxSide,
  }) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // The buffer is disposed by instantiateImageCodecWithSize.
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) =>
            UiImageEncoder.targetSize(width, height, maxSide),
      );
      image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData())!;
      return RgbaImage(
        pixels: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: image.width,
        height: image.height,
      );
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.invalidImage,
        cause: error,
      );
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
