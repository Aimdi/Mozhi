import 'package:mozhi/image_translate/models/models.dart';
import 'package:translation_repository/translation_repository.dart';

/// On-device text recognition (injectable for tests).
abstract interface class TextRecognitionService {
  /// Whether recognition works on this platform.
  bool get isSupported;

  /// Returns the text found in [image] (empty when there is none). [source]
  /// picks the script model. Throws [ImageTranslateException]
  /// (`recognitionFailed`) on failure.
  Future<String> recognize(PickedImage image, {required Language source});
}

/// [TextRecognitionService] for builds without an on-device recognizer
/// (the F-Droid build has no Google ML Kit): never supported, and
/// [recognize] always fails with `recognitionFailed`.
class UnavailableTextRecognitionService implements TextRecognitionService {
  const new();

  @override
  bool get isSupported => false;

  @override
  Future<String> recognize(PickedImage image, {required Language source}) =>
      Future.error(
        const ImageTranslateException(
          ImageTranslateErrorKind.recognitionFailed,
        ),
      );
}
