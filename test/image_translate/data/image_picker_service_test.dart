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

    test('maps a missing camera app', () async {
      stubPick(
        () async => throw PlatformException(code: 'no_available_camera'),
      );
      await expectLater(
        service.pick(ImagePickSource.camera),
        throwsA(
          const ImageTranslateException(ImageTranslateErrorKind.noCameraApp),
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

  group('retrieveLost', () {
    late PluginImagePickerService android;

    setUp(
      () => android = PluginImagePickerService(
        picker: picker,
        isWeb: false,
        isAndroid: true,
      ),
    );

    void stubLost(Future<LostDataResponse> Function() answer) =>
        when(picker.retrieveLostData).thenAnswer((_) => answer());

    test('only asks the plugin on Android', () async {
      expect(
        await PluginImagePickerService(
          picker: picker,
          isWeb: false,
          isAndroid: false,
        ).retrieveLost(),
        isNull,
      );
      expect(
        await PluginImagePickerService(
          picker: picker,
          isWeb: true,
          isAndroid: true,
        ).retrieveLost(),
        isNull,
      );
      verifyNever(picker.retrieveLostData);
    });

    test('returns null when nothing was lost', () async {
      stubLost(() async => LostDataResponse.empty());
      expect(await android.retrieveLost(), isNull);
    });

    test('returns the photo Android could not deliver', () async {
      stubLost(
        () async => LostDataResponse(
          file: XFile.fromData(
            pngBytes,
            name: 'camera.png',
            path: '/cache/camera.png',
          ),
          type: RetrieveType.image,
        ),
      );
      final image = await android.retrieveLost();
      expect(image!.bytes, pngBytes);
      expect(image.mimeType, 'image/png');
      expect(image.path, '/cache/camera.png');
    });

    test('takes the last of several files', () async {
      stubLost(
        () async => LostDataResponse(
          files: [
            XFile.fromData(jpegBytes, name: 'a.jpg'),
            XFile.fromData(pngBytes, name: 'b.png'),
          ],
          type: RetrieveType.image,
        ),
      );
      expect((await android.retrieveLost())!.bytes, pngBytes);
    });

    test('ignores lost videos and responses without a file', () async {
      stubLost(
        () async => LostDataResponse(
          file: XFile.fromData(pngBytes, name: 'clip.mp4'),
          type: RetrieveType.video,
        ),
      );
      expect(await android.retrieveLost(), isNull);
      stubLost(() async => LostDataResponse(type: RetrieveType.image));
      expect(await android.retrieveLost(), isNull);
    });

    test('reports the failure of the lost pick', () async {
      stubLost(
        () async => LostDataResponse(
          exception: PlatformException(code: 'camera_access_denied'),
          type: RetrieveType.image,
        ),
      );
      await expectLater(
        android.retrieveLost(),
        throwsA(
          const ImageTranslateException(
            ImageTranslateErrorKind.permissionDenied,
          ),
        ),
      );
    });

    test('maps plugin errors', () async {
      stubLost(() async => throw MissingPluginException());
      await expectLater(
        android.retrieveLost(),
        throwsA(
          const ImageTranslateException(ImageTranslateErrorKind.pickFailed),
        ),
      );
    });
  });

  group('LostImageRecovery', () {
    setUp(LostImageRecovery.reset);
    tearDown(LostImageRecovery.reset);

    test('keeps a recovered photo for the image page, once', () async {
      final fake = FakeImagePickerService()..lost = pngImage;
      expect(await LostImageRecovery.recover(picker: fake), isTrue);
      expect(LostImageRecovery.take(), same(pngImage));
      expect(LostImageRecovery.take(), isNull);
    });

    test('reports nothing to recover', () async {
      expect(
        await LostImageRecovery.recover(picker: FakeImagePickerService()),
        isFalse,
      );
      expect(LostImageRecovery.take(), isNull);
    });

    test('never throws', () async {
      final fake = FakeImagePickerService()
        ..lostError = const ImageTranslateException(
          ImageTranslateErrorKind.pickFailed,
        );
      expect(await LostImageRecovery.recover(picker: fake), isFalse);
    });

    test('defaults to the plugin (nothing to recover off Android)', () async {
      expect(await LostImageRecovery.recover(), isFalse);
    });
  });
}
