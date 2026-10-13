import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';

/// Draws a noisy [width] x [height] image and encodes it as PNG.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint();
  for (var x = 0; x < width; x += 4) {
    for (var y = 0; y < height; y += 4) {
      paint.color = ui.Color(0xFF000000 | ((x * 7919 + y * 104729) & 0xFFFFFF));
      canvas.drawRect(
        ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 4, 4),
        paint,
      );
    }
  }
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<(int, int)> _size(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final size = (frame.image.width, frame.image.height);
  frame.image.dispose();
  codec.dispose();
  return size;
}

void main() {
  group('UiImageEncoder.targetSize', () {
    test('keeps small images', () {
      final size = UiImageEncoder.targetSize(800, 600, 2048);
      expect(size.width, isNull);
      expect(size.height, isNull);
    });

    test('caps the long side', () {
      final landscape = UiImageEncoder.targetSize(4000, 3000, 2048);
      expect(landscape.width, 2048);
      expect(landscape.height, isNull);
      final portrait = UiImageEncoder.targetSize(3000, 4000, 2048);
      expect(portrait.width, isNull);
      expect(portrait.height, 2048);
    });
  });

  group('UiImageEncoder.encodePng', () {
    testWidgets('downscales to the long side', (tester) async {
      await tester.runAsync(() async {
        final source = await _png(300, 150);
        final png = await const UiImageEncoder().encodePng(
          source,
          maxSide: 100,
        );
        expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        expect(await _size(png), (100, 50));
      });
    });

    testWidgets('keeps images within the cap', (tester) async {
      await tester.runAsync(() async {
        final source = await _png(40, 80);
        final png = await const UiImageEncoder().encodePng(source);
        expect(await _size(png), (40, 80));
      });
    });

    testWidgets('shrinks until the PNG fits', (tester) async {
      await tester.runAsync(() async {
        final source = await _png(400, 200);
        final full = await const UiImageEncoder().encodePng(source);
        final png = await const UiImageEncoder(minSide: 16)
            .encodePng(source, maxBytes: full.lengthInBytes ~/ 3);
        expect(png.lengthInBytes, lessThanOrEqualTo(full.lengthInBytes ~/ 3));
        final (width, height) = await _size(png);
        expect(width, lessThan(400));
        expect(width, 2 * height);
      });
    });

    testWidgets('stops at the minimum size', (tester) async {
      await tester.runAsync(() async {
        final source = await _png(400, 200);
        final png = await const UiImageEncoder(minSide: 64)
            .encodePng(source, maxBytes: 1);
        expect(await _size(png), (64, 32));
      });
    });

    testWidgets('rejects data that is not an image', (tester) async {
      await tester.runAsync(() async {
        await expectLater(
          const UiImageEncoder().encodePng(Uint8List.fromList([1, 2, 3])),
          throwsA(
            const ImageTranslateException(ImageTranslateErrorKind.invalidImage),
          ),
        );
      });
    });
  });
}
