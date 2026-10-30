import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/data/method_channel_live_camera_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MethodChannelLiveCameraController.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Object? Function(MethodCall call) answer;

  setUp(() {
    calls = [];
    answer = (_) => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final result = answer(call);
      if (result is PlatformException) throw result;
      return result;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  MethodChannelLiveCameraController controller({bool android = true}) =>
      MethodChannelLiveCameraController(isAndroid: android);

  Map<String, Object?> frame({
    Object? pixels,
    int width = 4,
    int height = 2,
    int bytesPerRow = 4,
    int rotation = 90,
  }) => {
    'pixels': pixels ?? Uint8List(bytesPerRow * height),
    'width': width,
    'height': height,
    'bytesPerRow': bytesPerRow,
    'rotationDegrees': rotation,
    'timestamp': 1500,
  };

  group('requestAccess', () {
    test('maps the answers', () async {
      for (final (platform, access) in [
        ('granted', CameraAccess.granted),
        ('denied', CameraAccess.denied),
        ('blocked', CameraAccess.blocked),
        (null, CameraAccess.denied),
      ]) {
        answer = (_) => platform;
        expect(await controller().requestAccess(), access);
      }
      expect(calls.first.method, 'requestAccess');
    });

    test('is denied on errors and off Android', () async {
      answer = (_) => PlatformException(code: 'x');
      expect(await controller().requestAccess(), CameraAccess.denied);
      expect(
        await controller(android: false).requestAccess(),
        CameraAccess.denied,
      );
      messenger.setMockMethodCallHandler(channel, null);
      expect(await controller().requestAccess(), CameraAccess.denied);
    });
  });

  group('start', () {
    test('answers the preview', () async {
      answer = (_) => {
        'textureId': 3,
        'previewWidth': 1920,
        'previewHeight': 1080,
        'rotation': 90,
        'hasTorch': true,
        'minZoom': 1.0,
        'maxZoom': 10,
      };
      final preview = await controller().start();
      expect(
        preview,
        const LivePreview(
          textureId: 3,
          previewSize: Size(1920, 1080),
          rotation: 90,
          hasTorch: true,
          maxZoom: 10,
        ),
      );
      expect(preview.sizeOnScreen(0), const Size(1080, 1920));
      expect(preview.sizeOnScreen(90), const Size(1920, 1080));
      expect(calls.single.method, 'start');
    });

    test('a zoom range upside down is one ratio', () async {
      answer = (_) => {
        'textureId': 3,
        'previewWidth': 640,
        'previewHeight': 480,
        'rotation': 0,
        'minZoom': 2.0,
        'maxZoom': 1.0,
      };
      final preview = await controller().start();
      expect((preview.minZoom, preview.maxZoom), (2.0, 2.0));
      expect(preview.hasTorch, isFalse);
      expect(preview.sizeOnScreen(270), const Size(480, 640));
    });

    test('maps platform errors', () async {
      for (final (code, kind) in [
        ('no_camera', LiveCameraErrorKind.noCamera),
        ('permission', LiveCameraErrorKind.permission),
        ('in_use', LiveCameraErrorKind.inUse),
        ('disabled', LiveCameraErrorKind.disabled),
        ('background', LiveCameraErrorKind.background),
        ('failed', LiveCameraErrorKind.failed),
        ('other', LiveCameraErrorKind.failed),
      ]) {
        answer = (_) => PlatformException(code: code, message: 'why');
        await expectLater(
          controller().start(),
          throwsA(
            isA<LiveCameraException>()
                .having((error) => error.kind, 'kind', kind)
                .having((error) => error.message, 'message', 'why'),
          ),
        );
      }
    });

    test('refuses a malformed answer', () async {
      answer = (_) => {'textureId': 3, 'previewWidth': 0};
      await expectLater(
        controller().start(),
        throwsA(const LiveCameraException(LiveCameraErrorKind.failed)),
      );
      answer = (_) => {
        'textureId': 3,
        'previewWidth': 640,
        'previewHeight': 480,
        'rotation': 45,
      };
      await expectLater(
        controller().start(),
        throwsA(const LiveCameraException(LiveCameraErrorKind.failed)),
      );
    });

    test('there is no camera without the platform side', () async {
      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(
        controller().start(),
        throwsA(const LiveCameraException(LiveCameraErrorKind.noCamera)),
      );
      await expectLater(
        controller(android: false).start(),
        throwsA(const LiveCameraException(LiveCameraErrorKind.noCamera)),
      );
    });
  });

  group('nextFrame', () {
    test('answers the grey frame', () async {
      final pixels = Uint8List(8);
      answer = (_) => frame(pixels: pixels);
      final next = await controller().nextFrame();
      expect(next!.pixels, pixels);
      expect((next.width, next.height, next.bytesPerRow), (4, 2, 4));
      expect(next.rotationDegrees, 90);
      expect(next.timestamp, const Duration(microseconds: 1500));
      expect(next.toString(), contains('4x2'));
    });

    test('null once stopped, and off Android', () async {
      expect(await controller().nextFrame(), isNull);
      expect(await controller(android: false).nextFrame(), isNull);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await controller().nextFrame(), isNull);
    });

    test('a failed camera throws', () async {
      answer = (_) => PlatformException(code: 'in_use');
      await expectLater(
        controller().nextFrame(),
        throwsA(const LiveCameraException(LiveCameraErrorKind.inUse)),
      );
    });

    test('refuses frames that do not fit their size', () async {
      for (final bad in [
        frame(pixels: 'not bytes'),
        frame(width: 0),
        frame(width: 5000, bytesPerRow: 5000),
        frame(bytesPerRow: 3),
        frame(pixels: Uint8List(5)),
        frame(rotation: 45),
      ]) {
        answer = (_) => bad;
        await expectLater(
          controller().nextFrame(),
          throwsA(const LiveCameraException(LiveCameraErrorKind.failed)),
          reason: '$bad',
        );
      }
    });
  });

  group('controls', () {
    test('torch, zoom and stop are passed on', () async {
      final camera = controller();
      await camera.setTorch(on: true);
      await camera.setZoom(2.5);
      await camera.setZoom(double.nan);
      await camera.stop();
      expect(calls.map((call) => call.method), ['setTorch', 'setZoom', 'stop']);
      expect(calls[0].arguments, {'on': true});
      expect(calls[1].arguments, {'ratio': 2.5});
    });

    test('their platform errors are ignored', () async {
      answer = (_) => PlatformException(code: 'gone');
      await controller().setTorch(on: false);
      messenger.setMockMethodCallHandler(channel, null);
      await controller().stop();
      await controller(android: false).stop();
      expect(calls, hasLength(1));
    });

    test('takePicture answers the JPEG', () async {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1]);
      answer = (_) => jpeg;
      final still = await controller().takePicture();
      expect(still!.bytes, jpeg);
      expect(still.mimeType, 'image/jpeg');
      expect(still.name, MethodChannelLiveCameraController.stillName);
      expect(still.path, isNull);
    });

    test('takePicture refuses anything but a JPEG', () async {
      for (final bad in <Object?>[
        null,
        Uint8List(0),
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        PlatformException(code: 'busy'),
      ]) {
        answer = (_) => bad;
        expect(await controller().takePicture(), isNull);
      }
      messenger.setMockMethodCallHandler(channel, null);
      expect(await controller().takePicture(), isNull);
      expect(await controller(android: false).takePicture(), isNull);
    });

    test('openAppSettings and displayRotation', () async {
      answer = (call) => call.method == 'openAppSettings' ? true : 270;
      expect(await controller().openAppSettings(), isTrue);
      expect(await controller().displayRotation(), 270);
      answer = (call) => call.method == 'openAppSettings' ? null : 33;
      expect(await controller().openAppSettings(), isFalse);
      expect(await controller().displayRotation(), 0);
      answer = (_) => PlatformException(code: 'x');
      expect(await controller().openAppSettings(), isFalse);
      expect(await controller().displayRotation(), 0);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await controller().openAppSettings(), isFalse);
      expect(await controller().displayRotation(), 0);
      expect(await controller(android: false).openAppSettings(), isFalse);
      expect(await controller(android: false).displayRotation(), 0);
    });

    test('supported only on Android', () {
      // The test host is no Android device.
      expect(MethodChannelLiveCameraController().isSupported, isFalse);
      expect(controller().isSupported, isTrue);
      expect(controller(android: false).isSupported, isFalse);
      expect(liveCameraPlatformOf(controller()), isNotNull);
    });
  });

  group('UnsupportedLiveCameraController', () {
    test('never opens', () async {
      const camera = UnsupportedLiveCameraController();
      expect(camera.isSupported, isFalse);
      expect(await camera.requestAccess(), CameraAccess.denied);
      await expectLater(
        camera.start(),
        throwsA(const LiveCameraException(LiveCameraErrorKind.noCamera)),
      );
      expect(await camera.nextFrame(), isNull);
      await camera.setTorch(on: true);
      await camera.setZoom(2);
      expect(await camera.takePicture(), isNull);
      await camera.stop();
      expect(liveCameraPlatformOf(camera), isNull);
      // Tests run on a desktop host, not Android.
      expect(
        defaultLiveCameraController(),
        isA<UnsupportedLiveCameraController>(),
      );
    });
  });

  test('LiveCameraException', () {
    const error = LiveCameraException(LiveCameraErrorKind.inUse, message: 'm');
    expect(error, const LiveCameraException(LiveCameraErrorKind.inUse));
    expect(error.hashCode, LiveCameraErrorKind.inUse.hashCode);
    expect(error.toString(), 'LiveCameraException(inUse: m)');
    expect(
      const LiveCameraException(LiveCameraErrorKind.failed).toString(),
      'LiveCameraException(failed)',
    );
  });
}
