// The bindings of the default build, which contains no Google code (no ML
// Kit, Play services or Firebase): no on-device text recognition, so image
// translation offers only the methods that need no OCR library and says why.
//
// tool/play_prepare.sh replaces this file with
// tool/play/lib/platform/mlkit_bindings.dart (ML Kit text recognition) for
// the Play variant, so it must not import anything from ML Kit and must keep
// the same public API as that file (test/platform/mlkit_bindings_test.dart
// in both variants checks it). Offline translation does not depend on the
// variant: lib/platform/offline_engine.dart (Mozilla's Bergamot engine).
import 'package:mozhi/image_translate/data/text_recognition_service.dart';

/// Whether this build includes Google ML Kit (on-device text recognition).
/// True only in the Play variant (`tool/play_prepare.sh`).
const bool mlKitIncluded = false;

/// No on-device text recognizer in this build.
TextRecognitionService createTextRecognitionService() =>
    const UnavailableTextRecognitionService();
