import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';

/// A 4 x 2 JPEG whose EXIF orientation (6) says it is to be shown turned
/// 90 degrees clockwise: 2 x 4 upright (made with Pillow).
final Uint8List _rotatedJpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAAB'
  'AAYAAAAAAAD/2wBDAAIBAQEBAQIBAQECAgICAgQDAgICAgUEBAMEBgUGBgYFBgYG'
  'BwkIBgcJBwYGCAsICQoKCgoKBggLDAsKDAkKCgr/2wBDAQICAgICAgUDAwUKBwYH'
  'CgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoK'
  'Cgr/wAARCAACAAQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQF'
  'BgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKB'
  'kaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW'
  'V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKz'
  'tLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QA'
  'HwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQA'
  'AQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcY'
  'GRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE'
  'hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX'
  '2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD4st7e3tLdLS0gSKKJ'
  'AkUUahVRQMAADgADtRRRX80Z7/yO8V/18n/6Uz/erJf+RPhv+vcP/SUf/9k=',
);

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

  test('turns photos upright by their EXIF orientation', () async {
    // What text recognition reads (and the overlay's boxes refer to) is
    // the photo as Image.memory shows it.
    final image = await decoder.decode(_rotatedJpeg);
    expect((image.width, image.height), (2, 4));
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
