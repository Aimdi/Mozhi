import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
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
