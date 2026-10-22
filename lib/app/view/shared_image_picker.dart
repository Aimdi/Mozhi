import 'package:mozhi/app/shared_files.dart';
import 'package:mozhi/image_translate/data/image_picker_service.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';

/// The image screen's picker for an image shared from another app: the
/// screen asks its picker for a photo it could not receive when it opens
/// ([retrieveLost]), which is the shared image (once); picking a new one
/// uses `fallback` (default: the platform's picker).
class SharedImagePicker implements ImagePickerService {
  new(SharedFile file, {ImagePickerService? fallback})
    : _pending = PickedImage(
        bytes: file.bytes,
        mimeType: detectImageMimeType(file.bytes, name: file.name),
        name: file.name,
        path: file.path,
      ),
      _fallback = fallback ?? PluginImagePickerService();

  final ImagePickerService _fallback;
  PickedImage? _pending;

  @override
  bool get supportsCamera => _fallback.supportsCamera;

  @override
  Future<PickedImage?> pick(ImagePickSource source) => _fallback.pick(source);

  @override
  Future<PickedImage?> retrieveLost() async {
    final image = _pending;
    _pending = null;
    return image ?? await _fallback.retrieveLost();
  }
}
