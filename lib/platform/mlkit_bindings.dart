// The ML Kit build of the bindings: the one place (with
// lib/image_translate/data/mlkit_text_recognition_service.dart and
// packages/mlkit_translator) that reaches Google ML Kit.
//
// tool/fdroid_prepare.sh replaces this file with mlkit_bindings_stub.dart
// for the F-Droid build, so keep both files' public API identical
// (test/platform/mlkit_bindings_test.dart checks it).
import 'package:mlkit_translator/mlkit_translator.dart';
import 'package:mozhi/image_translate/data/mlkit_text_recognition_service.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Whether this build includes Google ML Kit (offline translation, language
/// identification and on-device text recognition).
const bool mlKitIncluded = true;

/// The on-device translator: ML Kit (available on Android and iOS only).
OfflineTranslator createOfflineTranslator() => MlKitOfflineTranslator();

/// The on-device text recognizer: ML Kit (Android and iOS only).
TextRecognitionService createTextRecognitionService() =>
    MlKitTextRecognitionService();
