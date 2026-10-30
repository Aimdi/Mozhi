import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/data/upright_frame.dart';

/// A 3 x 2 frame with rows 4 bytes apart (the 4th byte of a row is
/// padding):
///
///     1 2 3
///     4 5 6
CameraFrame _frame(int rotation) => CameraFrame(
  pixels: Uint8List.fromList([1, 2, 3, 99, 4, 5, 6, 99]),
  width: 3,
  height: 2,
  bytesPerRow: 4,
  rotationDegrees: rotation,
  timestamp: Duration.zero,
);

void main() {
  group('uprightFrame', () {
    test('keeps an upright frame as it is', () {
      final frame = _frame(0);
      final upright = uprightFrame(frame);
      expect(upright.pixels, same(frame.pixels));
      expect((upright.width, upright.height, upright.bytesPerRow), (3, 2, 4));
    });

    test('turns 90° clockwise', () {
      final upright = uprightFrame(_frame(90));
      expect((upright.width, upright.height, upright.bytesPerRow), (2, 3, 2));
      // 4 1
      // 5 2
      // 6 3
      expect(upright.pixels, [4, 1, 5, 2, 6, 3]);
    });

    test('turns 180°', () {
      final upright = uprightFrame(_frame(180));
      expect((upright.width, upright.height, upright.bytesPerRow), (3, 2, 3));
      expect(upright.pixels, [6, 5, 4, 3, 2, 1]);
    });

    test('turns 270° clockwise', () {
      final upright = uprightFrame(_frame(270));
      expect((upright.width, upright.height, upright.bytesPerRow), (2, 3, 2));
      // 3 6
      // 2 5
      // 1 4
      expect(upright.pixels, [3, 6, 2, 5, 1, 4]);
    });
  });
}
