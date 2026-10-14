import 'package:flutter_test/flutter_test.dart';
import 'package:mlkit_translator/mlkit_translator.dart';
import 'package:mozhi/image_translate/data/mlkit_text_recognition_service.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:mozhi/platform/mlkit_bindings.dart' as real;
import 'package:mozhi/platform/mlkit_bindings_stub.dart' as stub;

// tool/fdroid_prepare.sh deletes this test with the ML Kit code: it checks
// the ML Kit bindings against the stub that replaces them.
void main() {
  group('ML Kit bindings', () {
    test('include ML Kit', () {
      expect(real.mlKitIncluded, isTrue);
      expect(real.createOfflineTranslator(), isA<MlKitOfflineTranslator>());
      expect(
        real.createTextRecognitionService(),
        isA<MlKitTextRecognitionService>(),
      );
    });
  });

  group('stub bindings (F-Droid)', () {
    test('include no ML Kit', () {
      expect(stub.mlKitIncluded, isFalse);
    });

    test('create an offline translator that is never available', () {
      final translator = stub.createOfflineTranslator();
      expect(translator, isA<UnavailableOfflineTranslator>());
      expect(translator.isAvailable, isFalse);
    });

    test('create a text recognizer that is never supported', () {
      final recognizer = stub.createTextRecognitionService();
      expect(recognizer, isA<UnavailableTextRecognitionService>());
      expect(recognizer.isSupported, isFalse);
    });
  });
}
