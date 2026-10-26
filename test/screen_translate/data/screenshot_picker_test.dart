import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/screen_translate/data/screenshot_picker.dart';

void main() {
  test('offers nothing to pick: the screenshot is the only image', () async {
    const picker = ScreenshotPicker();
    expect(picker.supportsCamera, isFalse);
    expect(await picker.pick(ImagePickSource.gallery), isNull);
    expect(await picker.retrieveLost(), isNull);
  });
}
