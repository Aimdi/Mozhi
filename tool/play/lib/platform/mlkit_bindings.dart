// The Play variant of the bindings: on-device text recognition (camera and
// image translation) with Google ML Kit, which is closed source.
//
// tool/play_prepare.sh copies this file over lib/platform/mlkit_bindings.dart
// (the Google-free default) and adds google_mlkit_text_recognition to
// pubspec.yaml, so keep both files' public API identical
// (test/platform/mlkit_bindings_test.dart in both variants checks it).
// Offline translation is Mozilla's Bergamot engine in both variants
// (lib/platform/offline_engine.dart).
import 'package:mozhi/image_translate/data/mlkit_text_recognition_service.dart';
import 'package:mozhi/image_translate/data/text_recognition_service.dart';

/// Whether this build includes Google ML Kit (on-device text recognition).
/// True only in the Play variant (`tool/play_prepare.sh`).
const bool mlKitIncluded = true;

/// The on-device text recognizer: ML Kit (Android only).
TextRecognitionService createTextRecognitionService() =>
    MlKitTextRecognitionService();
