import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/image_translate/data/image_picker_service.dart';
import 'package:mozhi/image_translate/models/image_translate_exception.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';

/// The image screen's picker for an image shared from another app: the
/// screen asks its picker for a photo it could not receive when it opens
/// ([retrieveLost]), which is the shared image (once); picking a new one
/// uses `fallback` (default: the platform's picker).
///
/// [SharedImagePicker.failed] stands for a shared image that could not be
/// opened: [retrieveLost] reports why (once), as the screen shows a photo
/// the picker could not open.
class SharedImagePicker implements ImagePickerService {
  new(SharedFile file, {ImagePickerService? fallback})
    : _pending = PickedImage(
        bytes: file.bytes,
        mimeType: detectImageMimeType(file.bytes, name: file.name),
        name: file.name,
        path: file.path,
      ),
      _fallback = fallback ?? PluginImagePickerService();

  /// A shared image that could not be opened, for [error] (too large,
  /// could not be read).
  new failed(ImageTranslateException error, {ImagePickerService? fallback})
    : _error = error,
      _fallback = fallback ?? PluginImagePickerService();

  final ImagePickerService _fallback;
  PickedImage? _pending;
  ImageTranslateException? _error;

  @override
  bool get supportsCamera => _fallback.supportsCamera;

  @override
  Future<PickedImage?> pick(ImagePickSource source) => _fallback.pick(source);

  @override
  Future<PickedImage?> retrieveLost() async {
    if (_error case final error?) {
      _error = null;
      throw error;
    }
    final image = _pending;
    _pending = null;
    return image ?? await _fallback.retrieveLost();
  }
}
