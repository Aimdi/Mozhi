import 'package:mozhi/image_translate/data/image_picker_service.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';

/// The image translation's picker in the screen-translate window: there is
/// nothing to pick there (the screenshot is the only image), so it never
/// offers the camera and never returns an image.
class ScreenshotPicker implements ImagePickerService {
  const new();

  @override
  bool get supportsCamera => false;

  @override
  Future<PickedImage?> pick(ImagePickSource source) async => null;

  @override
  Future<PickedImage?> retrieveLost() async => null;
}
