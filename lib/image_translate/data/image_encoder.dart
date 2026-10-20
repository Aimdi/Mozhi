import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:mozhi/image_translate/models/models.dart';

/// Re-encodes images (injectable for tests).
abstract interface class ImageEncoder {
  /// Decodes [bytes] and encodes them as PNG with the long side capped at
  /// [maxSide]. When the PNG is larger than [maxBytes] it is re-encoded at
  /// smaller sizes until it fits (or reaches a minimum size).
  ///
  /// Throws [ImageTranslateException] (`invalidImage`) when [bytes] are not
  /// a decodable image.
  Future<Uint8List> encodePng(
    Uint8List bytes, {
    int maxSide = defaultMaxSide,
    int maxBytes = defaultMaxBytes,
  });
}

/// Long side cap for uploads: enough for the print of a sign or a menu
/// (and the largest size vision models look at without scaling down).
const int defaultMaxSide = 1600;

/// Keeps uploads well under the 1 to 4 MB body limits of the reverse
/// proxies in front of many Mozhi instances, and quick on mobile data.
const int defaultMaxBytes = 1500 * 1024;

/// Long side of the smaller copy sent once after the upload was turned down
/// (HTTP 413, or the connection dropped while sending it).
const int retryMaxSide = 1280;

/// Size of the smaller copy sent once after the upload was turned down.
const int retryMaxBytes = 900 * 1024;

/// [ImageEncoder] using the engine's codecs (`dart:ui`), so it works on
/// every platform including web.
class UiImageEncoder implements ImageEncoder {
  const new({this.minSide = 640});

  /// Re-encoding stops shrinking at this long side.
  final int minSide;

  @override
  Future<Uint8List> encodePng(
    Uint8List bytes, {
    int maxSide = defaultMaxSide,
    int maxBytes = defaultMaxBytes,
  }) async {
    var side = maxSide;
    while (true) {
      final (png, longSide) = await _encode(bytes, side);
      if (png.lengthInBytes <= maxBytes || longSide <= minSide) return png;
      // PNG size grows roughly with the pixel count.
      final ratio = math.sqrt(maxBytes / png.lengthInBytes) * 0.9;
      side = math.max(
        minSide,
        math.min(longSide - 1, (longSide * ratio).floor()),
      );
    }
  }

  /// Returns the PNG and its long side.
  static Future<(Uint8List, int)> _encode(Uint8List bytes, int maxSide) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // The buffer is disposed by instantiateImageCodecWithSize.
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) => targetSize(width, height, maxSide),
      );
      image = (await codec.getNextFrame()).image;
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      return (
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        math.max(image.width, image.height),
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

  /// Decode size for an image of [width] x [height] so that its long side
  /// is at most [maxSide] (never upscales; keeps the aspect ratio).
  static ui.TargetImageSize targetSize(int width, int height, int maxSide) {
    if (math.max(width, height) <= maxSide) return const ui.TargetImageSize();
    return width >= height
        ? ui.TargetImageSize(width: maxSide)
        : ui.TargetImageSize(height: maxSide);
  }
}
