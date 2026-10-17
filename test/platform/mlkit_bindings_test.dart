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

    test('create a text recognizer that is never supported', () {
      final recognizer = createTextRecognitionService();
      expect(recognizer, isA<UnavailableTextRecognitionService>());
      expect(recognizer.isSupported, isFalse);
    });
  });
}
