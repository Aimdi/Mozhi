import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/transcribe/data/screen_awake.dart';

import '../helpers/live_camera_fakes.dart';

class _FakeScreenAwake extends ScreenAwake {
  new() : super(isWeb: false);

  final calls = <bool>[];

  @override
  Future<void> setEnabled({required bool enabled}) async => calls.add(enabled);
}

void main() {
  setUpAll(registerLiveCameraFallbacks);

  late FakeLiveCamera camera;
  late MockTranslationRepository repository;
  late _FakeScreenAwake awake;

  setUp(() {
    camera = FakeLiveCamera();
    repository = MockTranslationRepository();
    when(() => repository.translate(any(), any()))
        .thenAnswer(bracketTranslation);
    awake = _FakeScreenAwake();
  });

  LiveCameraCubit build() => LiveCameraCubit(
    camera: camera,
    recognizer: FakeLiveRecognizer(),
    repository: repository,
    engine: offlineEngine,
    source: english,
    target: german,
    timing: const LiveCameraTiming(
      frameInterval: Duration(microseconds: 1),
      restartDelay: Duration.zero,
      translationRetry: Duration(milliseconds: 1),
    ),
    delay: (_) async {},
    screenAwake: awake,
  );

  group('LiveCameraCubit keeps the screen on', () {
    test('while the camera reads, not while paused', () async {
      final cubit = build();
      addTearDown(cubit.close);
      expect(awake.calls, isEmpty);
      await cubit.start();
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.running);
      expect(awake.calls, [true]);

      cubit.setForeground(visible: false);
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.paused);
      expect(awake.calls, [true, false]);

      cubit.setForeground(visible: true);
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.running);
      expect(awake.calls, [true, false, true]);
    });

    test('until the screen closes', () async {
      final cubit = build();
      await cubit.start();
      await pumpEventQueue();
      await cubit.close();
      expect(awake.calls, [true, false]);
    });

    test('never without a camera', () async {
      camera.isSupported = false;
      final cubit = build();
      await cubit.start();
      await cubit.close();
      expect(awake.calls, isEmpty);
    });

    test('with the platform by default', () async {
      final cubit = LiveCameraCubit(
        camera: camera,
        recognizer: FakeLiveRecognizer(),
        repository: repository,
        engine: offlineEngine,
        source: english,
        target: german,
      );
      await cubit.close();
    });
  });
}
