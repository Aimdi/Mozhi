import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/data/image_picker_service.dart';
import 'package:mozhi/image_translate/models/models.dart';

/// A photo Android could not hand over because it ended the app while the
/// camera (or the photo picker) was open: the camera app needs a lot of
/// memory, so this happens on many phones.
///
/// The app asks for it at start-up ([recover]) and then opens the image
/// screen, which continues with it ([take]).
abstract final class LostImageRecovery {
  static PickedImage? _pending;

  /// Asks [picker] (default: the `image_picker` plugin) for a photo lost
  /// that way and keeps it for [take]. Returns whether there is one. Never
  /// throws: a pick that had failed is forgotten.
  static Future<bool> recover({ImagePickerService? picker}) async {
    try {
      final image = await (picker ?? PluginImagePickerService()).retrieveLost();
      if (image != null) _pending = image;
    } on Object {
      // Nothing to continue with.
    }
    return _pending != null;
  }

  /// The recovered photo, once (null when there is none).
  static PickedImage? take() {
    final image = _pending;
    _pending = null;
    return image;
  }

  /// Forgets a recovered photo (tests).
  @visibleForTesting
  static void reset() => _pending = null;
}
