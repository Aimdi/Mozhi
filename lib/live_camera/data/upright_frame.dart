import 'package:flutter/foundation.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';

/// A [CameraFrame]'s grey pixels turned upright (one byte per pixel, rows
/// [bytesPerRow] bytes apart): what text recognition reads, and the
/// coordinates of the boxes it reports.
@immutable
class UprightFrame {
  const new({
    required this.pixels,
    required this.width,
    required this.height,
    required this.bytesPerRow,
  });

  final Uint8List pixels;
  final int width;
  final int height;
  final int bytesPerRow;
}

/// [frame] turned [CameraFrame.rotationDegrees] clockwise. An upright frame
/// is used as it is (no copy); a turned one is copied once into a tight
/// buffer.
UprightFrame uprightFrame(CameraFrame frame) {
  final source = frame.pixels;
  final width = frame.width;
  final height = frame.height;
  final stride = frame.bytesPerRow;
  switch (frame.rotationDegrees) {
    case 90:
      // (x, y) -> (height - 1 - y, x) in a height x width image.
      final out = Uint8List(width * height);
      for (var y = 0; y < height; y++) {
        final row = y * stride;
        final column = height - 1 - y;
        for (var x = 0; x < width; x++) {
          out[x * height + column] = source[row + x];
        }
      }
      return UprightFrame(
        pixels: out,
        width: height,
        height: width,
        bytesPerRow: height,
      );
    case 180:
      final out = Uint8List(width * height);
      for (var y = 0; y < height; y++) {
        final row = y * stride;
        final target = (height - 1 - y) * width + width - 1;
        for (var x = 0; x < width; x++) {
          out[target - x] = source[row + x];
        }
      }
      return UprightFrame(
        pixels: out,
        width: width,
        height: height,
        bytesPerRow: width,
      );
    case 270:
      // (x, y) -> (y, width - 1 - x) in a height x width image.
      final out = Uint8List(width * height);
      for (var y = 0; y < height; y++) {
        final row = y * stride;
        for (var x = 0; x < width; x++) {
          out[(width - 1 - x) * height + y] = source[row + x];
        }
      }
      return UprightFrame(
        pixels: out,
        width: height,
        height: width,
        bytesPerRow: height,
      );
    default:
      return UprightFrame(
        pixels: source,
        width: width,
        height: height,
        bytesPerRow: stride,
      );
  }
}
