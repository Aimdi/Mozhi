import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';

/// A [width] x [height] PNG: opaque red, with a transparent first pixel.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    )
    ..drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()
        ..color = const ui.Color(0x00000000)
        ..blendMode = ui.BlendMode.clear,
    );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  const decoder = UiRgbaImageDecoder();

  test('decodes to premultiplied RGBA', () async {
    final image = await decoder.decode(await _png(4, 3));
    expect((image.width, image.height), (4, 3));
    expect(image.pixels, hasLength(4 * 3 * 4));
    // The transparent pixel, then an opaque red one.
    expect(image.pixels.sublist(0, 8), [0, 0, 0, 0, 255, 0, 0, 255]);
  });

  test('caps the long side', () async {
    final wide = await decoder.decode(await _png(300, 100), maxSide: 150);
    expect((wide.width, wide.height), (150, 50));
    final tall = await decoder.decode(await _png(100, 300), maxSide: 150);
    expect((tall.width, tall.height), (50, 150));
  });

  test('rejects bytes that are no image', () async {
    await expectLater(
      decoder.decode(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(
        const ImageTranslateException(ImageTranslateErrorKind.invalidImage),
      ),
    );
  });
}
