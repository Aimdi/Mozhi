import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/screen_translate/cubit/screen_translate_settings_cubit.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';

import '../helpers.dart';

void main() {
  late MockScreenTranslateControls controls;

  const off = ScreenTranslateSupport(canAddTile: true);
  const allowed = ScreenTranslateSupport(canDrawOverlays: true);
  const running = ScreenTranslateSupport(
    bubbleRunning: true,
    canDrawOverlays: true,
  );

  setUp(() {
    controls = MockScreenTranslateControls();
    when(() => controls.isSupported).thenReturn(true);
    when(controls.status).thenAnswer((_) async => off);
    when(controls.requestOverlayPermission).thenAnswer((_) async => true);
    when(controls.requestNotificationPermission).thenAnswer((_) async => true);
    when(controls.startBubble).thenAnswer((_) async => true);
    when(controls.stopBubble).thenAnswer((_) async {});
    when(controls.requestAddTile)
        .thenAnswer((_) async => TileRequestResult.added);
  });

  ScreenTranslateSettingsCubit build() =>
      ScreenTranslateSettingsCubit(controls: controls);

  test('starts unknown and off', () {
    final state = build().state;
    expect(state.loaded, isFalse);
    expect(state.bubbleOn, isFalse);
    expect(state.notice, isNull);
  });

  blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
    'refresh reads the platform',
    setUp: () => when(controls.status).thenAnswer((_) async => running),
    build: build,
    act: (cubit) => cubit.refresh(),
    expect: () => const [
      ScreenTranslateSettingsState(support: running, loaded: true),
    ],
  );

  group('enableBubble', () {
    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'asks for overlays, then notifications, then starts the bubble',
      build: build,
      act: (cubit) => cubit.enableBubble(),
      expect: () => [
        isA<ScreenTranslateSettingsState>().having((s) => s.busy, 'busy', true),
        isA<ScreenTranslateSettingsState>()
            .having((s) => s.busy, 'busy', false)
            .having((s) => s.bubbleOn, 'on', true)
            .having((s) => s.support.canAddTile, 'tile', true)
            .having((s) => s.notice, 'notice', isNull),
      ],
      verify: (_) {
        verifyInOrder([
          controls.requestOverlayPermission,
          controls.requestNotificationPermission,
          controls.startBubble,
        ]);
      },
    );

    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'does not ask for overlays again when they are allowed',
      setUp: () => when(controls.status).thenAnswer((_) async => allowed),
      build: build,
      act: (cubit) => cubit.enableBubble(),
      skip: 1,
      expect: () => [
        isA<ScreenTranslateSettingsState>().having(
          (s) => s.bubbleOn,
          'on',
          true,
        ),
      ],
      verify: (_) => verifyNever(controls.requestOverlayPermission),
    );

    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'stops when overlays are not allowed',
      setUp: () =>
          when(controls.requestOverlayPermission)
              .thenAnswer((_) async => false),
      build: build,
      act: (cubit) => cubit.enableBubble(),
      skip: 1,
      expect: () => [
        isA<ScreenTranslateSettingsState>()
            .having((s) => s.bubbleOn, 'on', false)
            .having((s) => s.busy, 'busy', false)
            .having(
              (s) => s.notice,
              'notice',
              ScreenTranslateNotice.overlayDenied,
            ),
      ],
      verify: (_) => verifyNever(controls.startBubble),
    );

    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'starts without notifications, and says so',
      setUp: () =>
          when(controls.requestNotificationPermission)
              .thenAnswer((_) async => false),
      build: build,
      act: (cubit) => cubit.enableBubble(),
      skip: 1,
      expect: () => [
        isA<ScreenTranslateSettingsState>()
            .having((s) => s.bubbleOn, 'on', true)
            .having(
              (s) => s.notice,
              'notice',
              ScreenTranslateNotice.notificationsDenied,
            ),
      ],
    );

    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'reports a bubble that would not start',
      setUp: () => when(controls.startBubble).thenAnswer((_) async => false),
      build: build,
      act: (cubit) => cubit.enableBubble(),
      skip: 1,
      expect: () => [
        isA<ScreenTranslateSettingsState>()
            .having((s) => s.bubbleOn, 'on', false)
            .having(
              (s) => s.notice,
              'notice',
              ScreenTranslateNotice.bubbleFailed,
            ),
      ],
    );

    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'does nothing while busy or when on',
      build: build,
      seed: () => const ScreenTranslateSettingsState(support: running),
      act: (cubit) => cubit.enableBubble(),
      expect: () => const <ScreenTranslateSettingsState>[],
    );

    group('stops once the cubit is closed', () {
      late ScreenTranslateSettingsCubit cubit;

      setUp(() => cubit = build());

      Future<T> closing<T>(T value) async {
        await cubit.close();
        return value;
      }

      Future<void> check() async {
        await cubit.enableBubble();
        expect(cubit.state.bubbleOn, isFalse);
      }

      test('while reading the status', () async {
        when(controls.status).thenAnswer((_) => closing(off));
        await check();
      });

      test('while asking for overlays', () async {
        when(controls.requestOverlayPermission)
            .thenAnswer((_) => closing(true));
        await check();
      });

      test('while asking for notifications', () async {
        when(controls.requestNotificationPermission)
            .thenAnswer((_) => closing(true));
        await check();
      });

      test('while starting', () async {
        when(controls.startBubble).thenAnswer((_) => closing(true));
        await check();
      });

      test('while reading the status after starting', () async {
        var calls = 0;
        when(controls.status).thenAnswer(
          (_) => ++calls == 2 ? closing(allowed) : Future.value(allowed),
        );
        await check();
      });
    });

    test('stops once closed after a refused overlay', () async {
      final cubit = build();
      var statusCalls = 0;
      when(controls.status).thenAnswer((_) async {
        if (++statusCalls == 2) await cubit.close();
        return off;
      });
      when(controls.requestOverlayPermission).thenAnswer((_) async => false);
      await cubit.enableBubble();
      expect(cubit.state.notice, isNull);
    });
  });

  group('disableBubble', () {
    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'stops the bubble',
      build: build,
      seed: () =>
          const ScreenTranslateSettingsState(support: running, loaded: true),
      act: (cubit) => cubit.disableBubble(),
      expect: () => const [
        ScreenTranslateSettingsState(
          support: running,
          loaded: true,
          busy: true,
        ),
        ScreenTranslateSettingsState(support: allowed, loaded: true),
      ],
      verify: (_) => verify(controls.stopBubble).called(1),
    );

    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'does nothing when it is off',
      build: build,
      act: (cubit) => cubit.disableBubble(),
      expect: () => const <ScreenTranslateSettingsState>[],
    );

    test('stops once the cubit is closed', () async {
      final cubit = build()
        ..emit(const ScreenTranslateSettingsState(support: running));
      when(controls.stopBubble).thenAnswer((_) => cubit.close());
      await cubit.disableBubble();
      expect(cubit.state.busy, isTrue);
    });
  });

  group('addTile', () {
    for (final (result, notice) in [
      (TileRequestResult.added, ScreenTranslateNotice.tileAdded),
      (TileRequestResult.alreadyAdded, ScreenTranslateNotice.tileAlreadyAdded),
      (TileRequestResult.failed, ScreenTranslateNotice.tileFailed),
      (TileRequestResult.notAdded, null),
      (TileRequestResult.unsupported, null),
    ]) {
      blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
        '${result.name} tells ${notice?.name ?? 'nothing'}',
        setUp: () =>
            when(controls.requestAddTile).thenAnswer((_) async => result),
        build: build,
        act: (cubit) => cubit.addTile(),
        expect: () => [
          isA<ScreenTranslateSettingsState>().having(
            (s) => s.busy,
            'busy',
            true,
          ),
          isA<ScreenTranslateSettingsState>()
              .having((s) => s.busy, 'busy', false)
              .having((s) => s.notice, 'notice', notice)
              .having((s) => s.noticeSerial, 'serial', notice == null ? 0 : 1),
        ],
      );
    }

    blocTest<ScreenTranslateSettingsCubit, ScreenTranslateSettingsState>(
      'does nothing while busy',
      build: build,
      seed: () => const ScreenTranslateSettingsState(busy: true),
      act: (cubit) => cubit.addTile(),
      expect: () => const <ScreenTranslateSettingsState>[],
    );

    test('ignores the answer once closed', () async {
      final cubit = build();
      when(controls.requestAddTile).thenAnswer((_) async {
        await cubit.close();
        return TileRequestResult.added;
      });
      await cubit.addTile();
      expect(cubit.state.notice, isNull);
    });
  });

  test('refresh ignores the answer once closed', () async {
    final cubit = build();
    when(controls.status).thenAnswer((_) async {
      await cubit.close();
      return running;
    });
    await cubit.refresh();
    expect(cubit.state.loaded, isFalse);
  });

  test('a repeated notice is told apart', () {
    const state = ScreenTranslateSettingsState();
    final once = state.withNotice(ScreenTranslateNotice.tileAdded);
    final twice = once.withNotice(ScreenTranslateNotice.tileAdded);
    expect(once, isNot(twice));
    expect(twice.noticeSerial, 2);
    expect(twice.copyWith(busy: true).notice, ScreenTranslateNotice.tileAdded);
  });
}
