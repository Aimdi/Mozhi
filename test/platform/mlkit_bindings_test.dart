import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/platform/mlkit_bindings.dart';

// The default (Google-free) bindings. tool/play_prepare.sh replaces this
// test with tool/play/test/platform/mlkit_bindings_test.dart, which checks
// the ML Kit bindings of the Play variant.
void main() {
  group('default bindings (no ML Kit)', () {
    test('include no ML Kit', () {
      expect(mlKitIncluded, isFalse);
    });

    test('create the shared Tesseract recognizer', () {
      final recognizer = createTextRecognitionService();
      expect(recognizer, isA<TesseractTextRecognitionService>());
      expect(textRecognitionLanguageDataOf(recognizer), same(recognizer));
      expect(createTextRecognitionService(), same(recognizer));
      // The engine runs on Android only (the tests run on a desktop host).
      expect(recognizer.isSupported, isFalse);
    });
  });
}
