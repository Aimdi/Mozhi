// Play variant only: tool/play_prepare.sh copies this test over
// test/platform/mlkit_bindings_test.dart with the ML Kit bindings.
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/data/mlkit_text_recognition_service.dart';
import 'package:mozhi/platform/mlkit_bindings.dart';

void main() {
  group('ML Kit bindings (Play variant)', () {
    test('include ML Kit', () {
      expect(mlKitIncluded, isTrue);
    });

    test('create the ML Kit text recognizer', () {
      expect(
        createTextRecognitionService(),
        isA<MlKitTextRecognitionService>(),
      );
    });
  });
}
