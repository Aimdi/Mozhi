import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/screen_translate/cubit/screen_translate_cubit.dart';
import 'package:mozhi/screen_translate/screen_translate_host.dart';

import '../helpers.dart';

void main() {
  late MockScreenTranslateHost host;
  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1]);

  ScreenCaptured screenshot({bool blank = false}) =>
      ScreenCaptured(bytes: png, width: 10, height: 20, blank: blank);

  setUp(() {
    host = MockScreenTranslateHost();
    when(host.close).thenAnswer((_) async {});
    when(() => host.openTextInApp(any())).thenAnswer((_) async {});
    when(() => host.openLocationInApp(any())).thenAnswer((_) async {});
  });

  test('starts invisible, while the screenshot is taken', () {
    final cubit = ScreenTranslateCubit(host: host);
    expect(cubit.state.status, ScreenTranslateStatus.capturing);
    expect(cubit.state.isInvisible, isTrue);
    expect(cubit.state.screenshot, isNull);
  });

  group('start', () {
    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'shows the screenshot of an unlocked app',
      setUp: () => when(host.capture).thenAnswer((_) async => screenshot()),
      build: () => ScreenTranslateCubit(host: host),
      act: (cubit) async {
        await cubit.start();
        await cubit.start();
      },
      expect: () => [
        isA<ScreenTranslateState>()
            .having((s) => s.status, 'status', ScreenTranslateStatus.capturing)
            .having((s) => s.screenshot?.bytes, 'bytes', png),
        isA<ScreenTranslateState>()
            .having((s) => s.status, 'status', ScreenTranslateStatus.ready)
            .having((s) => s.screenshot?.mimeType, 'type', 'image/png')
            .having((s) => s.isInvisible, 'invisible', isFalse),
      ],
      verify: (_) => verify(host.capture).called(1),
    );

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'closes the window when the consent was declined',
      setUp: () =>
          when(host.capture)
              .thenAnswer((_) async => const ScreenCaptureDeclined()),
      build: () => ScreenTranslateCubit(host: host),
      act: (cubit) => cubit.start(),
      expect: () => const <ScreenTranslateState>[],
      verify: (_) => verify(host.close).called(1),
    );

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'reports a failed capture',
      setUp: () =>
          when(host.capture)
              .thenAnswer((_) async => const ScreenCaptureFailed('projection')),
      build: () => ScreenTranslateCubit(host: host),
      act: (cubit) => cubit.start(),
      expect: () => const [
        ScreenTranslateState(
          status: ScreenTranslateStatus.failed,
          failure: 'projection',
        ),
      ],
    );

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'reports a black frame without asking to unlock',
      setUp: () =>
          when(host.capture).thenAnswer((_) async => screenshot(blank: true)),
      build: () =>
          ScreenTranslateCubit(host: host, lock: FakeAppLock(locked: true)),
      act: (cubit) => cubit.start(),
      expect: () => const [
        ScreenTranslateState(status: ScreenTranslateStatus.blank),
      ],
    );

    test('does nothing once closed', () async {
      final capture = Completer<ScreenCapture>();
      when(host.capture).thenAnswer((_) => capture.future);
      final cubit = ScreenTranslateCubit(host: host);
      final started = cubit.start();
      await cubit.close();
      capture.complete(screenshot());
      await started;
      expect(cubit.state.status, ScreenTranslateStatus.capturing);
    });
  });

  group('the app lock', () {
    late FakeAppLock lock;

    setUp(() {
      lock = FakeAppLock(locked: true);
      when(host.capture).thenAnswer((_) async => screenshot());
    });

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'asks to unlock before anything is shown',
      build: () => ScreenTranslateCubit(host: host, lock: lock),
      act: (cubit) => cubit.start(),
      expect: () => [
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.capturing,
        ),
        isA<ScreenTranslateState>()
            .having((s) => s.status, 'status', ScreenTranslateStatus.unlocking)
            .having((s) => s.isInvisible, 'invisible', isTrue),
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.ready,
        ),
      ],
      verify: (_) => expect(lock.prompts, 1),
    );

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'a cancelled prompt leaves the lock card; unlock tries again',
      setUp: () => lock.unlockResult = false,
      build: () => ScreenTranslateCubit(host: host, lock: lock),
      act: (cubit) async {
        await cubit.start();
        lock.unlockResult = true;
        await cubit.unlock();
      },
      skip: 2,
      expect: () => [
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.locked,
        ),
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.unlocking,
        ),
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.ready,
        ),
      ],
      verify: (_) => expect(lock.prompts, 2),
    );

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'a failing prompt keeps it locked',
      setUp: () => lock.unlockError = Exception('prompt'),
      build: () => ScreenTranslateCubit(host: host, lock: lock),
      act: (cubit) => cubit.start(),
      skip: 2,
      expect: () => [
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.locked,
        ),
      ],
    );

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'hides the screenshot when the app locks again, until unlocked',
      setUp: () => lock.locked = false,
      build: () => ScreenTranslateCubit(host: host, lock: lock),
      act: (cubit) async {
        await cubit.start();
        lock.setLocked(locked: true);
        await pumpEventQueue();
        lock.setLocked(locked: false);
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.locked,
        ),
        isA<ScreenTranslateState>().having(
          (s) => s.status,
          'status',
          ScreenTranslateStatus.ready,
        ),
      ],
      verify: (_) => expect(lock.prompts, 0),
    );

    blocTest<ScreenTranslateCubit, ScreenTranslateState>(
      'unlock does nothing unless locked',
      setUp: () => lock.locked = false,
      build: () => ScreenTranslateCubit(host: host, lock: lock),
      act: (cubit) async {
        await cubit.start();
        await cubit.unlock();
      },
      skip: 2,
      expect: () => const <ScreenTranslateState>[],
    );

    test('a closed cubit ignores the prompt and the lock', () async {
      lock.gate = Completer<void>();
      final cubit = ScreenTranslateCubit(host: host, lock: lock);
      final started = cubit.start();
      await pumpEventQueue();
      expect(cubit.state.status, ScreenTranslateStatus.unlocking);
      await cubit.close();
      lock.gate!.complete();
      await started;
      lock.setLocked(locked: true);
      await pumpEventQueue();
      expect(cubit.state.status, ScreenTranslateStatus.unlocking);
    });
  });

  group('leaving', () {
    test('close, open in the app and open a location use the host', () async {
      final cubit = ScreenTranslateCubit(host: host);
      await cubit.closeWindow();
      await cubit.openInApp('Hallo');
      await cubit.openLocation('/settings/offline');
      verify(host.close).called(1);
      verify(() => host.openTextInApp('Hallo')).called(1);
      verify(() => host.openLocationInApp('/settings/offline')).called(1);
      await cubit.close();
    });
  });
}
