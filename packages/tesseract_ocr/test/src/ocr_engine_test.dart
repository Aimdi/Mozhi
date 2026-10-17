import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tesseract_ocr/src/engine/engine_factory_stub.dart' as stub;
import 'package:tesseract_ocr/tesseract_ocr.dart';

void main() {
  group('OcrImage', () {
    test('defaults to tightly packed RGBA', () {
      final image = OcrImage(Uint8List(4 * 3 * 2), width: 3, height: 2);
      expect(image.bytesPerPixel, 4);
      expect(image.bytesPerLine, 12);
      expect(image.toString(), 'OcrImage(3x2, 4 B/px)');
    });

    test('accepts padded rows and gray or RGB pixels', () {
      expect(
        OcrImage(
          Uint8List(16 + 3),
          width: 3,
          height: 2,
          bytesPerPixel: 1,
          bytesPerLine: 16,
        ).bytesPerLine,
        16,
      );
      expect(
        OcrImage(Uint8List(18), width: 3, height: 2, bytesPerPixel: 3).width,
        3,
      );
    });

    test('rejects invalid layouts', () {
      expect(
        () => OcrImage(Uint8List(0), width: 0, height: 1),
        throwsArgumentError,
      );
      expect(
        () => OcrImage(Uint8List(8), width: 1, height: 1, bytesPerPixel: 2),
        throwsArgumentError,
      );
      expect(
        () => OcrImage(Uint8List(8), width: 2, height: 1, bytesPerLine: 4),
        throwsArgumentError,
      );
      expect(
        () => OcrImage(Uint8List(7), width: 1, height: 2),
        throwsArgumentError,
      );
    });
  });

  test('OcrResult compares by value', () {
    const result = OcrResult(text: 'Hello', meanConfidence: 90);
    expect(result, const OcrResult(text: 'Hello', meanConfidence: 90));
    expect(
      result.hashCode,
      const OcrResult(text: 'Hello', meanConfidence: 90).hashCode,
    );
    expect(result, isNot(const OcrResult(text: 'Hello')));
    expect(result.toString(), 'OcrResult(5 chars, 90%)');
  });

  test('TesseractEngineException describes itself', () {
    expect(
      const TesseractEngineException('boom').toString(),
      'TesseractEngineException(boom)',
    );
  });

  group('stub (web)', () {
    test('is never supported and fails every recognition', () async {
      expect(stub.tesseractPlatformSupported, isFalse);
      final engine = stub.createTesseractEngine();
      expect(engine, isA<stub.UnsupportedOcrEngine>());
      await expectLater(
        engine.recognize(
          OcrImage(Uint8List(4), width: 1, height: 1),
          dataPath: '/data',
          languages: const ['eng'],
        ),
        throwsUnsupportedError,
      );
      await engine.release();
      await engine.dispose();
    });
  });

  test('the platform engine is not supported on a desktop host', () {
    expect(tesseractPlatformSupported, isFalse);
    expect(createTesseractEngine(), isA<OcrEngine>());
  });
}
