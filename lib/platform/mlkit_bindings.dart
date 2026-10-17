// The bindings of the default build, which contains no Google code (no ML
// Kit, Play services or Firebase): on-device text recognition is Tesseract
// with downloadable tessdata_fast language data
// (lib/platform/text_recognition.dart, packages/tesseract_ocr); the web
// app has none.
//
// tool/play_prepare.sh replaces this file with
// tool/play/lib/platform/mlkit_bindings.dart (ML Kit text recognition) for
// the Play variant, so it must not import anything from ML Kit and must keep
// the same public API as that file (test/platform/mlkit_bindings_test.dart
// in both variants checks it). Offline translation does not depend on the
// variant: lib/platform/offline_engine.dart (Mozilla's Bergamot engine).
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/platform/text_recognition.dart';

/// Whether this build includes Google ML Kit (on-device text recognition).
/// True only in the Play variant (`tool/play_prepare.sh`).
const bool mlKitIncluded = false;

/// The on-device text recognizer: Tesseract (Android; never supported on
/// the web).
TextRecognitionService createTextRecognitionService() =>
    defaultTextRecognitionService();
