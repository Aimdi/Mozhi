// The build of the bindings without Google ML Kit (F-Droid).
//
// tool/fdroid_prepare.sh copies this file over mlkit_bindings.dart and
// removes the ML Kit packages, so it must not import anything from ML Kit
// and must keep the same public API as mlkit_bindings.dart.
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/offline/data/unavailable_offline_translator.dart';
import 'package:translation_repository/translation_repository.dart';

/// Whether this build includes Google ML Kit (offline translation, language
/// identification and on-device text recognition).
const bool mlKitIncluded = false;

/// No on-device translator in this build.
OfflineTranslator createOfflineTranslator() =>
    const UnavailableOfflineTranslator();

/// No on-device text recognizer in this build.
TextRecognitionService createTextRecognitionService() =>
    const UnavailableTextRecognitionService();
