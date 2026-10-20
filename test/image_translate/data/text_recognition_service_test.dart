import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('RecognizedText', () {
    test('compares text and confidence', () {
      const read = RecognizedText('Hola', confidence: 80);
      expect(read, const RecognizedText('Hola', confidence: 80));
      expect(read, isNot(const RecognizedText('Hola')));
      expect(
        read.hashCode,
        const RecognizedText('Hola', confidence: 80).hashCode,
      );
      expect(read.toString(), 'RecognizedText(4 chars, 80%)');
    });
  });

  group('UnavailableTextRecognitionService', () {
    const service = UnavailableTextRecognitionService();

    test('is never supported', () {
      expect(service.isSupported, isFalse);
    });

    test('fails to recognize', () async {
      await expectLater(
        service.recognize(
          PickedImage(
            bytes: Uint8List(0),
            mimeType: 'image/png',
            path: '/x.png',
          ),
          source: Language.auto,
        ),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.recognitionFailed,
          ),
        ),
      );
    });
  });
}
