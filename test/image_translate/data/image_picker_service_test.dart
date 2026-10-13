import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';

import '../helpers/helpers.dart';

class MockImagePicker extends Mock implements ImagePicker;

void main() {
  late MockImagePicker picker;
  late PluginImagePickerService service;

  setUpAll(() => registerFallbackValue(ImageSource.gallery));

  setUp(() {
    picker = MockImagePicker();
    service = PluginImagePickerService(picker: picker, isWeb: false);
  });

  void stubPick(Future<XFile?> Function() answer) {
    when(
      () => picker.pickImage(
        source: any(named: 'source'),
        maxWidth: any(named: 'maxWidth'),
        maxHeight: any(named: 'maxHeight'),
        imageQuality: any(named: 'imageQuality'),
        requestFullMetadata: any(named: 'requestFullMetadata'),
      ),
    ).thenAnswer((_) => answer());
  }

  test('defaults to the plugin picker', () {
    expect(PluginImagePickerService.new, returnsNormally);
  });

  group('supportsCamera', () {
    test('asks the plugin', () {
      when(() => picker.supportsImageSource(ImageSource.camera))
          .thenReturn(true);
      expect(service.supportsCamera, isTrue);
      when(() => picker.supportsImageSource(ImageSource.camera))
          .thenReturn(false);
      expect(service.supportsCamera, isFalse);
    });

    test('is false when the plugin throws', () {
      when(() => picker.supportsImageSource(any()))
          .thenThrow(UnimplementedError());
      expect(service.supportsCamera, isFalse);
    });
  });

  group('pick', () {
    test('picks a downscaled image without metadata', () async {
      stubPick(
        () async =>
            XFile.fromData(pngBytes, name: 'shot.png', path: '/tmp/shot.png'),
      );
      final image = await service.pick(ImagePickSource.camera);
      expect(image, isNotNull);
      expect(image!.bytes, pngBytes);
      expect(image.mimeType, 'image/png');
      expect(image.name, 'shot.png');
      expect(image.path, '/tmp/shot.png');
      verify(
        () => picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 2048,
          maxHeight: 2048,
          imageQuality: 92,
          requestFullMetadata: false,
        ),
      ).called(1);
    });

    test('uses the gallery source', () async {
      stubPick(() async => XFile.fromData(jpegBytes, name: 'a.jpg'));
      final image = await service.pick(ImagePickSource.gallery);
      expect(image!.mimeType, 'image/jpeg');
      verify(
        () => picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: any(named: 'maxWidth'),
          maxHeight: any(named: 'maxHeight'),
          imageQuality: any(named: 'imageQuality'),
          requestFullMetadata: any(named: 'requestFullMetadata'),
        ),
      ).called(1);
    });

    test('has no path on web', () async {
      service = PluginImagePickerService(picker: picker, isWeb: true);
      stubPick(
        () async => XFile.fromData(pngBytes, name: 'a.png', path: 'blob:x'),
      );
      final image = await service.pick(ImagePickSource.gallery);
      expect(image!.path, isNull);
    });

    test('returns null when dismissed', () async {
      stubPick(() async => null);
      expect(await service.pick(ImagePickSource.gallery), isNull);
    });

    test('maps denied access', () async {
      stubPick(
        () async => throw PlatformException(code: 'camera_access_denied'),
      );
      await expectLater(
        service.pick(ImagePickSource.camera),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.permissionDenied,
          ),
        ),
      );
    });

    test('maps other platform errors', () async {
      stubPick(() async => throw PlatformException(code: 'invalid_image'));
      await expectLater(
        service.pick(ImagePickSource.gallery),
        throwsA(
          const ImageTranslateException(ImageTranslateErrorKind.pickFailed),
        ),
      );
    });

    test('maps unexpected errors', () async {
      stubPick(() async => throw StateError('boom'));
      await expectLater(
        service.pick(ImagePickSource.gallery),
        throwsA(
          const ImageTranslateException(ImageTranslateErrorKind.pickFailed),
        ),
      );
    });

    test('maps unreadable files', () async {
      stubPick(() async => XFile('/does/not/exist.png'));
      await expectLater(
        service.pick(ImagePickSource.gallery),
        throwsA(
          const ImageTranslateException(ImageTranslateErrorKind.pickFailed),
        ),
      );
    });
  });
}
