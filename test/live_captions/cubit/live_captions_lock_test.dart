import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/live_captions/cubit/live_captions_cubit.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../app_lock/helpers/fake_app_lock_platform.dart';
import '../helpers.dart';

/// An app lock the test locks and unlocks.
class _FakeAppLock implements AppLock {
  @override
  bool isLocked = false;

  final _changes = StreamController<bool>.broadcast();

  void set({required bool locked}) {
    isLocked = locked;
    _changes.add(locked);
  }

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  Future<bool> unlock() async {
    set(locked: false);
    return true;
  }

  @override
  void noteBackground() {}

  @override
  void noteForeground() {}

  Future<void> dispose() => _changes.close();
}

const _locked = CaptionLine.notice('bar:appLocked');

void main() {
  late FakeCaptionsHost host;
  late FakeCaptionRecognizer recognizer;
  late FakeOverlayControls overlay;
  late MockTranslationRepository repository;
  late MockDeviceConditions conditions;
  late StreamController<DeviceConditionsSnapshot> heat;
  late _FakeAppLock lock;

  setUpAll(() {
    registerFallbackValue(deepl);
    registerFallbackValue(
      const TranslationRequest(text: '', source: english, target: german),
    );
  });

  setUp(() {
    host = FakeCaptionsHost();
    recognizer = FakeCaptionRecognizer();
    overlay = FakeOverlayControls();
    repository = MockTranslationRepository();
    conditions = MockDeviceConditions();
    heat = StreamController.broadcast();
    lock = _FakeAppLock();
    when(() => conditions.latest).thenReturn(DeviceConditionsSnapshot.unknown);
    when(() => conditions.changes).thenAnswer((_) => heat.stream);
    // "Hola" -> "[en] Hola".
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      return Stream.value(resultOf('[${request.target.code}] ${request.text}'));
    });
  });

  tearDown(() async {
    await host.dispose();
    await heat.close();
    await lock.dispose();
  });

  LiveCaptionsCubit build({AppLock? appLock}) => LiveCaptionsCubit(
    host: host,
    repository: repository,
    engine: () => deepl,
    source: Language.auto,
    target: english,
    recognizer: recognizer,
    overlay: overlay,
    conditions: conditions,
    lock: appLock ?? lock,
    describe: (text) => 'bar:${text.name}',
  );

  Future<LiveCaptionsCubit> running({AppLock? appLock}) async {
    final cubit = build(appLock: appLock);
    await cubit.load();
    await cubit.start();
    await settle();
    expect(cubit.state.status, LiveCaptionsStatus.running);
    return cubit;
  }

  /// The text of every line shown on the bar.
  List<String> shownTexts() => [
    for (final line in host.shown) ...[line.translation, line.original],
  ];

  group('app lock', () {
    test('the bar says "Mozhi is locked" and shows no captions', () async {
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      expect(
        host.bar,
        const CaptionLine(original: 'Hola', translation: '[en] Hola'),
      );

      lock.set(locked: true);
      await settle();
      expect(host.bar, _locked);

      final before = host.shown.length;
      recognizer.recording.phrase('Secreto', language: 'es', index: 1);
      await settle();
      // Captioned into the transcript (behind the lock), not on the bar.
      expect(cubit.state.entries.last.translation, '[en] Secreto');
      expect(host.shown.length, before);
      expect(shownTexts().where((text) => text.contains('Secreto')), isEmpty);
      await cubit.close();
    });

    test('notices are not shown either while locked', () async {
      final cubit = await running();
      lock.set(locked: true);
      await settle();
      heat.add(const DeviceConditionsSnapshot(thermal: ThermalStatus.severe));
      await settle();

      expect(cubit.state.pause, LiveCaptionsPause.hot);
      expect(host.bar, _locked);
      expect(host.shown.where((line) => line == _locked), hasLength(1));
      await cubit.close();
    });

    test('unlocked, the last caption comes back', () async {
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      lock.set(locked: true);
      await settle();
      recognizer.recording.phrase('Adiós', language: 'es', index: 1);
      await settle();

      lock.set(locked: false);
      await settle();

      expect(
        host.bar,
        const CaptionLine(original: 'Adiós', translation: '[en] Adiós'),
      );
      await cubit.close();
    });

    test('unlocked while hot or silent, the notice comes back', () async {
      final cubit = await running();
      lock.set(locked: true);
      await settle();
      heat.add(const DeviceConditionsSnapshot(thermal: ThermalStatus.severe));
      await settle();
      lock.set(locked: false);
      await settle();
      expect(host.bar, const CaptionLine.notice('bar:hot'));
      await cubit.close();
    });

    test('unlocked before any caption, it listens', () async {
      final cubit = await running();
      lock.set(locked: true);
      await settle();
      lock.set(locked: false);
      await settle();
      expect(host.bar, const CaptionLine.notice('bar:listening'));
      await cubit.close();
    });

    test('started while locked, the bar says so', () async {
      lock.isLocked = true;
      final cubit = await running();
      expect(host.bar, _locked);
      expect(host.shown, [_locked]);
      await cubit.close();
    });

    test('a lock while stopped shows nothing', () async {
      final cubit = build();
      await cubit.load();
      lock.set(locked: true);
      await settle();
      lock.set(locked: false);
      await settle();
      expect(host.shown, isEmpty);
      await cubit.close();
    });

    test('the phone unlocked: the bar shows the caption again', () async {
      final cubit = await running();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      host.sendEvent(CaptionBarEvent.deviceLocked);
      await settle();
      final before = host.shown.length;

      host.sendEvent(CaptionBarEvent.deviceUnlocked);
      await settle();

      expect(host.shown.length, before + 1);
      expect(
        host.bar,
        const CaptionLine(original: 'Hola', translation: '[en] Hola'),
      );
      await cubit.close();
    });

    test('the phone unlocked after the lock timeout passed in its sleep: '
        'the app lock checks and the bar stays locked', () async {
      final platform = FakeAppLockPlatform(unlocked: true);
      final timers = FakeTimers();
      final controller = AppLockController(
        platform: platform,
        timeout: AppLockTimeout.after1Minute,
        timer: timers.call,
      );
      addTearDown(controller.dispose);
      await settle();
      expect(controller.isLocked, isFalse);

      final cubit = await running(appLock: controller);
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      controller.noteBackground();
      host.sendEvent(CaptionBarEvent.deviceLocked);
      await settle();
      // The phone slept for 10 minutes; the timer has not fired.
      platform.leave(const Duration(minutes: 10));
      expect(timers.active, hasLength(1));

      host.sendEvent(CaptionBarEvent.deviceUnlocked);
      await settle();

      expect(controller.isLocked, isTrue);
      expect(host.bar, _locked);
      expect(platform.unlockedWrites, [false]);
      await cubit.close();
    });

    test(
      'the phone unlocked within the timeout: the caption comes back',
      () async {
        final platform = FakeAppLockPlatform(unlocked: true);
        final controller = AppLockController(
          platform: platform,
          timeout: AppLockTimeout.after5Minutes,
          timer: FakeTimers().call,
        );
        addTearDown(controller.dispose);
        await settle();

        final cubit = await running(appLock: controller);
        recognizer.recording.phrase('Hola', language: 'es');
        await settle();
        controller.noteBackground();
        host.sendEvent(CaptionBarEvent.deviceLocked);
        await settle();
        platform.leave(const Duration(seconds: 30));

        host.sendEvent(CaptionBarEvent.deviceUnlocked);
        await settle();

        expect(controller.isLocked, isFalse);
        expect(
          host.bar,
          const CaptionLine(original: 'Hola', translation: '[en] Hola'),
        );
        await cubit.close();
      },
    );

    test('without a lock, captions show as before', () async {
      final cubit = LiveCaptionsCubit(
        host: host,
        repository: repository,
        engine: () => deepl,
        source: Language.auto,
        target: english,
        recognizer: recognizer,
        describe: (text) => 'bar:${text.name}',
      );
      await cubit.load();
      await cubit.start();
      await settle();
      recognizer.recording.phrase('Hola', language: 'es');
      await settle();
      expect(
        host.bar,
        const CaptionLine(original: 'Hola', translation: '[en] Hola'),
      );
      await cubit.close();
    });
  });

  group('requestStart', () {
    test('starts once loaded', () async {
      final cubit = build();
      final loading = cubit.load();
      await cubit.requestStart();
      expect(host.starts, 0);
      await loading;
      await settle();
      expect(host.starts, 1);
      expect(cubit.state.status, LiveCaptionsStatus.running);
      await cubit.close();
    });

    test('starts right away when loaded', () async {
      final cubit = build();
      await cubit.load();
      await cubit.requestStart();
      await settle();
      expect(host.starts, 1);
      await cubit.close();
    });

    test('does nothing where captions cannot run', () async {
      recognizer.ready = false;
      final cubit = build();
      final loading = cubit.load();
      await cubit.requestStart();
      await loading;
      await settle();
      expect(cubit.state.status, LiveCaptionsStatus.needsModel);
      expect(host.starts, 0);
      await cubit.close();
    });

    test('does nothing once closed', () async {
      final cubit = build();
      await cubit.close();
      await cubit.requestStart();
      expect(host.starts, 0);
    });
  });

  test('describes the locked bar in English by default', () async {
    final cubit = LiveCaptionsCubit(
      host: host,
      repository: repository,
      engine: () => deepl,
      source: Language.auto,
      target: english,
      recognizer: recognizer,
      lock: lock..isLocked = true,
    );
    await cubit.load();
    await cubit.start();
    await settle();
    expect(host.bar, const CaptionLine.notice('Mozhi is locked'));
    await cubit.close();
  });
}
