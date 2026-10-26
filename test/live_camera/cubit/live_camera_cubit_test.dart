import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/live_camera_fakes.dart';

const _fast = LiveCameraTiming(
  frameInterval: Duration(microseconds: 1),
  restartDelay: Duration.zero,
  translationRetry: Duration(milliseconds: 1),
);

void main() {
  setUpAll(registerLiveCameraFallbacks);

  late FakeLiveCamera camera;
  late FakeLiveRecognizer recognizer;
  late MockTranslationRepository repository;
  late MockDeviceConditions conditions;
  late StreamController<DeviceConditionsSnapshot> conditionChanges;
  late List<Duration> delays;

  setUp(() {
    camera = FakeLiveCamera();
    recognizer = FakeLiveRecognizer();
    repository = MockTranslationRepository();
    when(() => repository.translate(any(), any()))
        .thenAnswer(bracketTranslation);
    conditions = MockDeviceConditions();
    conditionChanges = StreamController.broadcast();
    when(() => conditions.latest).thenReturn(DeviceConditionsSnapshot.unknown);
    when(() => conditions.changes).thenAnswer((_) => conditionChanges.stream);
    delays = [];
  });

  tearDown(() => conditionChanges.close());

  LiveCameraCubit build({
    Language source = english,
    Language target = german,
    TranslationEngine? engine,
    FakeAppLock? lock,
    LiveCameraTiming timing = _fast,
    int minSightings = 2,
    Object recognizerOverride = const Object(),
  }) => LiveCameraCubit(
    camera: camera,
    recognizer: recognizerOverride is TextRecognitionService
        ? recognizerOverride
        : recognizer,
    repository: repository,
    engine: engine ?? offlineEngine,
    source: source,
    target: target,
    lock: lock,
    conditions: conditions,
    timing: timing,
    delay: (duration) async => delays.add(duration),
    minSightings: minSightings,
  );

  /// A cubit that runs and waits for its first frame.
  Future<LiveCameraCubit> running({
    Language source = english,
    TranslationEngine? engine,
    int minSightings = 2,
    LiveCameraTiming timing = _fast,
  }) async {
    final cubit = build(
      source: source,
      engine: engine,
      minSightings: minSightings,
      timing: timing,
    );
    addTearDown(cubit.close);
    await cubit.start();
    await pumpEventQueue();
    expect(cubit.state.status, LiveCameraStatus.running);
    return cubit;
  }

  /// Hands out a frame reading [paragraphs] and lets it be read.
  Future<void> show(
    List<TextParagraph> paragraphs, {
    CameraFrame? frame,
  }) async {
    recognizer.answers.add(layoutOf(paragraphs));
    camera.push(frame ?? testFrame());
    await pumpEventQueue();
  }

  group('start', () {
    test('asks for the camera, opens it and reads', () async {
      final cubit = await running();

      expect(camera.accessRequests, 1);
      expect(camera.starts, 1);
      expect(cubit.state.preview, testPreview);
      expect(cubit.state.zoom, 1);
      expect(camera.waitingForFrame, isTrue);
      // English is read with its data.
      await show([paragraph('Hello world')]);
      expect(recognizer.codes.single, ['eng']);
      expect(recognizer.sizes.single.bytesPerPixel, 1);
    });

    test('starts only once', () async {
      final cubit = await running();
      await cubit.start();
      expect(camera.starts, 1);
    });

    blocTest<LiveCameraCubit, LiveCameraState>(
      'is denied when the camera is refused',
      setUp: () => camera.access = [CameraAccess.denied],
      build: build,
      act: (cubit) => cubit.start(),
      expect: () => [
        isA<LiveCameraState>().having(
          (state) => state.status,
          'status',
          LiveCameraStatus.requestingAccess,
        ),
        isA<LiveCameraState>().having(
          (state) => state.status,
          'status',
          LiveCameraStatus.denied,
        ),
      ],
      verify: (_) => expect(camera.starts, 0),
    );

    test('asks again after a refusal', () async {
      camera.access = [CameraAccess.denied, CameraAccess.granted];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.denied);
      // Only from a refusal.
      await cubit.retryCamera();

      await cubit.retryAccess();
      await pumpEventQueue();

      expect(camera.accessRequests, 2);
      expect(cubit.state.status, LiveCameraStatus.running);
      await cubit.retryAccess();
      expect(camera.accessRequests, 2);
    });

    test('blocked: opens the settings and asks again on return', () async {
      camera.access = [CameraAccess.blocked, CameraAccess.granted];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.blocked);

      await cubit.openSettings();
      expect(camera.settingsOpened, 1);
      cubit
        ..setForeground(visible: false)
        ..setForeground(visible: true);
      await pumpEventQueue();

      expect(camera.accessRequests, 2);
      expect(cubit.state.status, LiveCameraStatus.running);
    });

    test('blocked: a return without the settings asks nothing', () async {
      camera.access = [CameraAccess.blocked];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      camera.settingsOpen = false;
      await cubit.openSettings();
      cubit
        ..setForeground(visible: false)
        ..setForeground(visible: true);
      await pumpEventQueue();

      expect(camera.accessRequests, 1);
      expect(cubit.state.status, LiveCameraStatus.blocked);
    });

    test('is unsupported without a camera', () async {
      camera.isSupported = false;
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.unsupported);
      expect(camera.accessRequests, 0);
    });

    test('is unsupported without raw pixel recognition', () async {
      final cubit = build(recognizerOverride: FilesOnlyRecognizer());
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.unsupported);
    });

    test('a camera failure can be retried', () async {
      camera.startErrors.add(
        const LiveCameraException(LiveCameraErrorKind.inUse),
      );
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.failed);
      expect(cubit.state.cameraError, LiveCameraErrorKind.inUse);

      await cubit.retryCamera();
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.running);
      expect(cubit.state.cameraError, isNull);
    });

    test('any other start error is a failure', () async {
      camera.startErrors.add(Exception('boom'));
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.cameraError, LiveCameraErrorKind.failed);
    });

    test('a permission taken away asks again', () async {
      camera.startErrors.add(
        const LiveCameraException(LiveCameraErrorKind.permission),
      );
      camera.access = [CameraAccess.granted, CameraAccess.granted];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.denied);
      await cubit.retryAccess();
      await pumpEventQueue();
      expect(camera.accessRequests, 2);
      expect(cubit.state.status, LiveCameraStatus.running);
    });

    test('a start refused in the background starts again soon', () async {
      camera.startErrors.add(
        const LiveCameraException(LiveCameraErrorKind.background),
      );
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.starting);
      await pumpEventQueue();
      expect(camera.starts, 2);
      expect(cubit.state.status, LiveCameraStatus.running);
    });
  });

  group('read-translate loop', () {
    test('frames become blocks and their translations', () async {
      final cubit = await running();

      await show([paragraph('Hello world')]);

      final block = cubit.state.blocks.single;
      expect(block.text, 'Hello world');
      expect(block.translation, '<Hello world>de');
      expect(cubit.state.translatedBlocks, [block]);
      expect(cubit.state.frameSize, const Size(4, 2));
      // The sensor turns 90° and the frame came upright: a turned display.
      expect(cubit.state.displayRotation, 90);
      final request =
          verify(() => repository.translate(offlineEngine, captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(request.text, 'Hello world');
      expect(request.source, english);
      expect(request.target, german);
    });

    test('tracking keeps an unchanged block and its box', () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);
      final first = cubit.state.blocks.single;

      await show([
        paragraph('Hello world', box: const Rect.fromLTWH(12, 11, 100, 20)),
      ]);
      // Recognition noise keeps the text too.
      await show([
        paragraph('Hello vorld', box: const Rect.fromLTWH(11, 10, 100, 20)),
      ]);

      final block = cubit.state.blocks.single;
      expect(block.id, first.id);
      expect(block.box, first.box);
      expect(block.text, 'Hello world');
      expect(block.seen, 3);
      verify(() => repository.translate(any(), any())).called(1);
    });

    test('only a changed block is translated again', () async {
      final cubit = await running();
      await show([
        paragraph('Hello world'),
        paragraph('Exit', box: const Rect.fromLTWH(10, 100, 50, 20)),
      ]);
      verify(() => repository.translate(any(), any())).called(1);

      await show([
        paragraph('Goodbye moon'),
        paragraph('Exit', box: const Rect.fromLTWH(10, 100, 50, 20)),
      ]);

      final captured = verify(() => repository.translate(any(), captureAny()))
          .captured;
      expect((captured.single as TranslationRequest).text, 'Goodbye moon');
      expect(cubit.state.blocks.map((block) => block.translation), [
        '<Goodbye moon>de',
        '<Exit>de',
      ]);
    });

    test(
      'a block read once with low confidence waits for a second sight',
      () async {
        final cubit = await running();
        await show([paragraph('Hello world', confidence: 60)]);
        expect(cubit.state.blocks.single.hasTranslation, isFalse);
        verifyNever(() => repository.translate(any(), any()));

        await show([paragraph('Hello world', confidence: 60)]);
        expect(cubit.state.blocks.single.translation, '<Hello world>de');
      },
    );

    test('specks are not blocks', () async {
      final cubit = await running();
      await show([
        paragraph('a'),
        paragraph('noise', confidence: 20),
        paragraph('Readable text'),
      ]);
      expect(cubit.state.blocks.map((block) => block.text), ['Readable text']);
    });

    test('a block found again later is translated from memory', () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);
      for (var i = 0; i < 3; i++) {
        await show(const []);
      }
      expect(cubit.state.blocks, isEmpty);

      await show([paragraph('Hello world')]);

      expect(cubit.state.blocks.single.translation, '<Hello world>de');
      verify(() => repository.translate(any(), any())).called(1);
    });

    test('a frame of another size starts the blocks over', () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);
      final first = cubit.state.blocks.single;

      await show([paragraph('Hello world')], frame: testFrame(rotation: 90));

      expect(cubit.state.frameSize, const Size(2, 4));
      expect(cubit.state.displayRotation, 0);
      expect(cubit.state.blocks.single.id, isNot(first.id));
      // Its translation is still in memory.
      verify(() => repository.translate(any(), any())).called(1);
    });

    test('one frame is in flight at a time', () async {
      final cubit = await running();
      final gate = recognizer.gate = Completer<void>();
      recognizer.answers.addAll([
        layoutOf([paragraph('One')]),
        layoutOf([paragraph('One')]),
      ]);
      camera
        ..push(testFrame())
        ..push(testFrame());
      await pumpEventQueue();

      // The second frame is not asked for while the first is read.
      expect(camera.frameRequests, 1);
      expect(recognizer.calls, 1);

      gate.complete();
      await pumpEventQueue();

      expect(camera.frameRequests, 3);
      expect(recognizer.calls, 2);
      expect(camera.maxFramesInFlight, 1);
      expect(recognizer.maxInFlight, 1);
      expect(cubit.state.status, LiveCameraStatus.running);
    });

    test('several new blocks go in one request', () async {
      final cubit = await running();
      await show([
        paragraph('First line'),
        paragraph('Second line', box: const Rect.fromLTWH(10, 60, 100, 20)),
      ]);
      final request =
          verify(() => repository.translate(any(), captureAny()))
                  .captured
                  .single
              as TranslationRequest;
      expect(request.text, 'First line\n\nSecond line');
      expect(cubit.state.blocks.map((block) => block.translation), [
        '<First line>de',
        '<Second line>de',
      ]);
    });

    test('a network engine that merged blocks gets no more requests', () async {
      when(() => repository.translate(any(), any())).thenAnswer(
        (_) => Stream.value(
          const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'Erste Zeile. Zweite Zeile.',
          ),
        ),
      );
      final cubit = await running(engine: googleEngine);
      await show([
        paragraph('First line.'),
        paragraph('Second line.', box: const Rect.fromLTWH(10, 60, 100, 20)),
      ]);
      verify(() => repository.translate(googleEngine, any())).called(1);
      expect(cubit.state.blocks.map((block) => block.translation), [
        'Erste Zeile.',
        'Zweite Zeile.',
      ]);
    });

    test('the offline engine translates merged blocks one by one', () async {
      when(() => repository.translate(any(), any())).thenAnswer((invocation) {
        final request = invocation.positionalArguments[1] as TranslationRequest;
        return Stream.value(
          TranslationResult(
            engineId: 'offline',
            engineName: 'Offline',
            text: request.text.contains('\n\n')
                ? 'merged'
                : '<${request.text}>',
          ),
        );
      });
      final cubit = await running();
      await show([
        paragraph('First line'),
        paragraph('Second line', box: const Rect.fromLTWH(10, 60, 100, 20)),
      ]);
      verify(() => repository.translate(any(), any())).called(3);
      expect(cubit.state.blocks.map((block) => block.translation), [
        '<First line>',
        '<Second line>',
      ]);
    });

    test('a single block keeps a translation of several paragraphs', () async {
      when(() => repository.translate(any(), any())).thenAnswer(
        (_) => Stream.value(
          const TranslationResult(
            engineId: 'offline',
            engineName: 'Offline',
            text: 'Eins\n\nZwei',
          ),
        ),
      );
      final cubit = await running();
      await show([paragraph('One two')]);
      expect(cubit.state.blocks.single.translation, 'Eins\n\nZwei');
    });

    test('repeated recognition failures are reported until it reads', () async {
      final cubit = await running();
      recognizer.error = const ImageTranslateException(
        ImageTranslateErrorKind.recognitionFailed,
      );
      for (var i = 0; i < 3; i++) {
        camera.push(testFrame());
        await pumpEventQueue();
      }
      expect(cubit.state.recognitionFailed, isTrue);

      recognizer.error = null;
      await show([paragraph('Hello world')]);
      expect(cubit.state.recognitionFailed, isFalse);
    });
  });

  group('recognition data', () {
    test('missing data is offered and nothing is read', () async {
      final cubit = build(source: french);
      addTearDown(cubit.close);
      await cubit.start();
      await pumpEventQueue();

      expect(cubit.state.status, LiveCameraStatus.running);
      expect(cubit.state.ocrMissing?.language, FakeLiveRecognizer.fra);
      expect(camera.frameRequests, 0);

      recognizer.installed['fra'] = 1;
      await cubit.ocrInstalled();
      await pumpEventQueue();

      expect(cubit.state.ocrMissing, isNull);
      expect(camera.frameRequests, 1);
    });

    test('data installed elsewhere is picked up', () async {
      final cubit = build(source: french);
      addTearDown(cubit.close);
      await cubit.start();
      await pumpEventQueue();

      recognizer.installed['fra'] = 1;
      recognizer.changed();
      await pumpEventQueue();

      expect(cubit.state.ocrMissing, isNull);
      expect(camera.waitingForFrame, isTrue);
    });

    test('"Detect language" without any data guesses a language', () async {
      recognizer.installed = {};
      final cubit = build(source: Language.auto);
      addTearDown(cubit.close);
      await cubit.start();
      await pumpEventQueue();
      expect(cubit.state.ocrMissing?.guessed, isTrue);
    });

    test('"Detect language" reads with the installed data', () async {
      final cubit = await running(source: Language.auto);
      await show([paragraph('Hallo Welt')]);
      expect(recognizer.codes.single, ['eng', 'deu']);
      expect(cubit.state.blocks.single.text, 'Hallo Welt');
    });

    test('a language no data reads is unsupported', () async {
      final cubit = build(
        source: const Language(code: 'xh', name: 'Xhosa'),
      );
      addTearDown(cubit.close);
      await cubit.start();
      await pumpEventQueue();
      expect(cubit.state.ocrUnsupported, isTrue);
      expect(camera.frameRequests, 0);
    });

    test('data deleted while reading is offered again', () async {
      final cubit = await running();
      recognizer.answers.add(
        const OcrDataMissingException(FakeLiveRecognizer.eng),
      );
      camera.push(testFrame());
      await pumpEventQueue();
      expect(cubit.state.ocrMissing?.language, FakeLiveRecognizer.eng);
      expect(camera.frameRequests, 1);
    });

    test('a new source reads with its data, the blocks anew', () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);

      await cubit.setSource(german);
      await cubit.setSource(german);
      await pumpEventQueue();
      expect(cubit.state.source, german);
      expect(cubit.state.blocks, isEmpty);
      await show([paragraph('Hallo Welt')]);
      expect(recognizer.codes.last, ['deu']);
    });
  });

  group('engine', () {
    test('a failure is shown and retried after a while', () async {
      var calls = 0;
      when(() => repository.translate(any(), any())).thenAnswer((invocation) {
        if (calls++ == 0) return Stream.error(StateError('down'));
        return bracketTranslation(invocation);
      });
      final cubit = await running(
        timing: const LiveCameraTiming(
          frameInterval: Duration(microseconds: 1),
          translationRetry: Duration(milliseconds: 60),
        ),
      );
      await show([paragraph('Hello world')]);
      expect(cubit.state.translationError, isA<StateError>());
      expect(cubit.state.blocks.single.hasTranslation, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pumpEventQueue();

      expect(cubit.state.translationError, isNull);
      expect(cubit.state.blocks.single.translation, '<Hello world>de');
    });

    test('consent stops translating until it is granted', () async {
      const consent = ConsentRequiredException(
        kind: ConsentKind.cloudProvider,
        destination: CloudProviderDestination('Claude'),
        engineId: 'ai:claude',
      );
      var calls = 0;
      when(() => repository.translate(any(), any())).thenAnswer((invocation) {
        if (calls++ == 0) return Stream.error(consent);
        return bracketTranslation(invocation);
      });
      final cubit = await running();
      await show([paragraph('Hello world')]);
      expect(cubit.state.consent, consent);

      await show([paragraph('Hello world')]);
      verify(() => repository.translate(any(), any())).called(1);

      cubit.consentGranted();
      await pumpEventQueue();
      expect(cubit.state.consent, isNull);
      expect(cubit.state.blocks.single.translation, '<Hello world>de');
      // Only once.
      cubit.consentGranted();
    });

    test('a new engine translates the blocks again', () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);

      cubit
        ..setEngine(googleEngine)
        ..setEngine(googleEngine);
      await pumpEventQueue();

      expect(cubit.state.engine, googleEngine);
      verify(() => repository.translate(googleEngine, any())).called(1);
    });

    test('a new target translates the blocks again', () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);

      await cubit.setTarget(french);
      await cubit.setTarget(Language.auto);
      await pumpEventQueue();

      expect(cubit.state.target, french);
      expect(cubit.state.blocks.single.translation, '<Hello world>fr');
    });

    test('a slow request of the old engine is dropped', () async {
      final slow = StreamController<TranslationResult>();
      when(() => repository.translate(offlineEngine, any()))
          .thenAnswer((_) => slow.stream);
      final cubit = await running();
      await show([paragraph('Hello world')]);

      cubit.setEngine(googleEngine);
      await pumpEventQueue();
      expect(cubit.state.blocks.single.translation, '<Hello world>de');
      expect(slow.hasListener, isFalse);
      await slow.close();
    });
  });

  group('pausing', () {
    test('in the background, and on again in front', () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);

      cubit.setForeground(visible: false);
      expect(cubit.state.status, LiveCameraStatus.paused);
      expect(cubit.state.pauseReason, LivePauseReason.background);
      expect(cubit.state.blocks, isEmpty);
      expect(camera.stops, 1);
      // Twice changes nothing.
      cubit.setForeground(visible: false);
      expect(camera.stops, 1);

      cubit.setForeground(visible: true);
      await pumpEventQueue();
      expect(camera.starts, 2);
      expect(cubit.state.status, LiveCameraStatus.running);
    });

    test('a pause while the camera opens closes it', () async {
      final cubit = build();
      addTearDown(cubit.close);
      final started = cubit.start();
      cubit.setForeground(visible: false);
      await started;
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.paused);
    });

    test('while locked', () async {
      final lock = FakeAppLock(isLocked: true);
      final cubit = build(lock: lock);
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.paused);
      expect(cubit.state.pauseReason, LivePauseReason.locked);
      expect(camera.accessRequests, 0);

      lock.unlockNow();
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.running);

      lock.lockNow();
      await pumpEventQueue();
      expect(cubit.state.pauseReason, LivePauseReason.locked);
      // Locked and in the background: the lock is named.
      cubit.setForeground(visible: false);
      expect(cubit.state.pauseReason, LivePauseReason.locked);
      lock.unlockNow();
      await pumpEventQueue();
      expect(cubit.state.pauseReason, LivePauseReason.background);
    });

    test('a pause before the start waits with it', () async {
      final cubit = build()..setForeground(visible: false);
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.status, LiveCameraStatus.paused);
      cubit.setForeground(visible: true);
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.running);
    });

    test('a message stays while paused', () async {
      camera.access = [CameraAccess.denied];
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      cubit
        ..setForeground(visible: false)
        ..setForeground(visible: true);
      expect(cubit.state.status, LiveCameraStatus.denied);
    });

    test('reads less often while the phone is hot', () async {
      when(() => conditions.latest).thenReturn(
        const DeviceConditionsSnapshot(thermal: ThermalStatus.severe),
      );
      final cubit = await running();
      expect(cubit.state.strain, DeviceStrain.heat);
      await show([paragraph('Hello world')]);
      expect(delays.single, greaterThan(const Duration(seconds: 1)));

      conditionChanges.add(DeviceConditionsSnapshot.unknown);
      await pumpEventQueue();
      expect(cubit.state.strain, isNull);
    });

    test('reads less often to save battery', () async {
      final cubit = await running();
      conditionChanges.add(const DeviceConditionsSnapshot(powerSave: true));
      await pumpEventQueue();
      expect(cubit.state.strain, DeviceStrain.batterySaver);
    });

    test('pauses while the phone is critically hot', () async {
      final cubit = await running();
      conditionChanges.add(
        const DeviceConditionsSnapshot(thermal: ThermalStatus.critical),
      );
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.paused);
      expect(cubit.state.pauseReason, LivePauseReason.heat);

      conditionChanges.add(
        const DeviceConditionsSnapshot(thermal: ThermalStatus.moderate),
      );
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.running);
    });

    test('starts paused when the phone is already too hot', () async {
      when(() => conditions.latest).thenReturn(
        const DeviceConditionsSnapshot(thermal: ThermalStatus.emergency),
      );
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.start();
      expect(cubit.state.pauseReason, LivePauseReason.heat);
    });
  });

  group('camera failures', () {
    test('a failing frame fails the camera', () async {
      final cubit = await running();
      camera.push(const LiveCameraException(LiveCameraErrorKind.disabled));
      await pumpEventQueue();
      expect(cubit.state.status, LiveCameraStatus.failed);
      expect(cubit.state.cameraError, LiveCameraErrorKind.disabled);
      expect(cubit.state.preview, isNull);
    });

    test('an unexpected frame error fails it too', () async {
      final cubit = await running();
      camera.push(Exception('broken'));
      await pumpEventQueue();
      expect(cubit.state.cameraError, LiveCameraErrorKind.failed);
    });

    test('a camera Android closed is opened again', () async {
      final cubit = await running();
      camera.push(null);
      await pumpEventQueue();
      expect(camera.starts, 2);
      expect(cubit.state.status, LiveCameraStatus.running);
    });

    test('a camera that keeps closing fails', () async {
      final cubit = await running();
      for (var i = 0; i < 4; i++) {
        camera.push(null);
        await pumpEventQueue();
      }
      expect(cubit.state.status, LiveCameraStatus.failed);
    });

    test('a camera without frames stalled', () async {
      final cubit = build(
        timing: const LiveCameraTiming(frameTimeout: Duration(milliseconds: 5)),
      );
      addTearDown(cubit.close);
      await cubit.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();
      expect(cubit.state.cameraError, LiveCameraErrorKind.stalled);
    });
  });

  group('controls', () {
    test('torch', () async {
      final cubit = await running();
      await cubit.setTorch(on: true);
      await cubit.setTorch(on: true);
      expect(cubit.state.torchOn, isTrue);
      expect(camera.torch, [true]);
      await cubit.setTorch(on: false);
      expect(camera.torch, [true, false]);
    });

    test('no torch without a flashlight', () async {
      camera.preview = const LivePreview(
        textureId: 1,
        previewSize: Size(640, 480),
        rotation: 90,
      );
      final cubit = await running();
      await cubit.setTorch(on: true);
      expect(cubit.state.torchOn, isFalse);
      expect(camera.torch, isEmpty);
    });

    test("zoom within the camera's range", () async {
      final cubit = await running();
      await show([paragraph('Hello world')]);
      await cubit.setZoom(2);
      expect(cubit.state.zoom, 2);
      expect(cubit.state.blocks, isEmpty);
      await cubit.setZoom(20);
      await cubit.setZoom(8.001);
      await cubit.setZoom(double.nan);
      expect(cubit.state.zoom, 8);
      expect(camera.zooms, [2, 8]);
    });

    test('rotation is asked again when the window turns', () async {
      final cubit = await running();
      camera.rotation = 270;
      await cubit.refreshRotation();
      expect(cubit.state.displayRotation, 270);
      await cubit.refreshRotation();
    });

    test('freeze hands out the still and closes the camera', () async {
      final still = PickedImage(
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
        mimeType: 'image/jpeg',
      );
      camera.picture = still;
      final cubit = await running();

      final frozen = await cubit.freeze();

      expect(frozen, same(still));
      expect(cubit.state.status, LiveCameraStatus.frozen);
      expect(cubit.state.still, same(still));
      expect(camera.stops, 1);
      expect(await cubit.freeze(), isNull);
    });

    test('a failed freeze reads on', () async {
      final cubit = await running();
      expect(await cubit.freeze(), isNull);
      expect(cubit.state.freezeFailures, 1);
      expect(cubit.state.status, LiveCameraStatus.running);
      await show([paragraph('Hello world')]);
      expect(cubit.state.blocks, isNotEmpty);
    });

    test('a pause while freezing drops the still', () async {
      camera.pictureGate = Completer();
      final cubit = await running();
      final frozen = cubit.freeze();
      expect(cubit.state.status, LiveCameraStatus.freezing);
      cubit.setForeground(visible: false);
      camera.pictureGate!.complete(null);
      expect(await frozen, isNull);
      expect(cubit.state.status, LiveCameraStatus.paused);
    });

    test('close stops the camera', () async {
      final cubit = await running();
      await cubit.close();
      expect(camera.stops, 1);
    });
  });

  group('isReadableLiveParagraph', () {
    test('needs two letters and some confidence', () {
      expect(isReadableLiveParagraph(paragraph('ok')), isTrue);
      expect(isReadableLiveParagraph(paragraph('-')), isFalse);
      expect(isReadableLiveParagraph(paragraph('ab', confidence: 40)), isFalse);
      expect(
        isReadableLiveParagraph(paragraph('longer text', confidence: 40)),
        isTrue,
      );
      expect(
        isReadableLiveParagraph(
          const TextParagraph(text: 'no score', box: Rect.zero),
        ),
        isTrue,
      );
    });
  });
}
