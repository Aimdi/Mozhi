import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app_lock/cubit/app_lock_cubit.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/app_lock/data/app_lock_platform.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../helpers/fake_app_lock_platform.dart';

void main() {
  late FakeAppLockPlatform platform;
  late AppLockController lock;

  setUp(() async {
    platform = FakeAppLockPlatform();
    lock = AppLockController(
      platform: platform,
      timeout: AppLockTimeout.immediately,
      timer: FakeTimers().call,
    );
    await pumpEventQueue();
    expect(lock.status, AppLockStatus.locked);
  });

  tearDown(() => lock.dispose());

  const locked = AppLockState(status: AppLockStatus.locked);
  const unlocked = AppLockState(status: AppLockStatus.unlocked);

  group(AppLockState, () {
    test('starts checking', () {
      const state = AppLockState();
      expect(state.status, AppLockStatus.checking);
      expect(state.prompting, isFalse);
      expect(state.failed, isFalse);
      expect(state.unlocked, isFalse);
    });

    test('copies with the given fields', () {
      expect(
        locked.copyWith(prompting: true, failed: true),
        const AppLockState(
          status: AppLockStatus.locked,
          prompting: true,
          failed: true,
        ),
      );
      expect(locked.copyWith(), locked);
      expect(unlocked.unlocked, isTrue);
    });
  });

  group(AppLockCubit, () {
    test('starts with the status of the lock', () {
      final cubit = AppLockCubit(lock);
      addTearDown(cubit.close);

      expect(cubit.state, locked);
    });

    blocTest<AppLockCubit, AppLockState>(
      'follows the lock',
      build: () => AppLockCubit(lock),
      act: (_) => lock.configure(AppLockTimeout.off),
      expect: () => const [unlocked],
    );

    blocTest<AppLockCubit, AppLockState>(
      'unlocks with the prompt',
      build: () => AppLockCubit(lock),
      act: (cubit) => cubit.unlock(),
      expect: () => const [
        AppLockState(status: AppLockStatus.locked, prompting: true),
        AppLockState(status: AppLockStatus.unlocked, prompting: true),
        unlocked,
      ],
    );

    blocTest<AppLockCubit, AppLockState>(
      'says when the prompt did not unlock',
      setUp: () => platform.promptResult = AppLockPromptResult.cancelled,
      build: () => AppLockCubit(lock),
      act: (cubit) => cubit.unlock(),
      expect: () => const [
        AppLockState(status: AppLockStatus.locked, prompting: true),
        AppLockState(status: AppLockStatus.locked, failed: true),
      ],
    );

    blocTest<AppLockCubit, AppLockState>(
      'clears the failure when it tries again',
      setUp: () => platform.promptResult = AppLockPromptResult.cancelled,
      build: () => AppLockCubit(lock),
      seed: () => locked.copyWith(failed: true),
      act: (cubit) async {
        platform.promptResult = AppLockPromptResult.success;
        await cubit.unlock();
      },
      expect: () => const [
        AppLockState(status: AppLockStatus.locked, prompting: true),
        AppLockState(status: AppLockStatus.unlocked, prompting: true),
        unlocked,
      ],
    );

    blocTest<AppLockCubit, AppLockState>(
      'ignores Unlock while the prompt shows',
      setUp: () => platform.holdPrompt = Completer(),
      build: () => AppLockCubit(lock),
      act: (cubit) async {
        unawaited(cubit.unlock());
        await pumpEventQueue();
        await cubit.unlock();
        platform.holdPrompt!.complete(AppLockPromptResult.cancelled);
        await pumpEventQueue();
      },
      expect: () => const [
        AppLockState(status: AppLockStatus.locked, prompting: true),
        AppLockState(status: AppLockStatus.locked, failed: true),
      ],
      verify: (_) => expect(platform.prompts, hasLength(1)),
    );

    blocTest<AppLockCubit, AppLockState>(
      'opens the prompt by itself once',
      build: () => AppLockCubit(lock),
      act: (cubit) async {
        await cubit.autoUnlock();
        lock.noteBackground();
        await cubit.autoUnlock();
      },
      expect: () => const [
        AppLockState(status: AppLockStatus.locked, prompting: true),
        AppLockState(status: AppLockStatus.unlocked, prompting: true),
        unlocked,
      ],
      verify: (_) => expect(platform.prompts, hasLength(1)),
    );

    blocTest<AppLockCubit, AppLockState>(
      'does not open the prompt again after a cancel',
      setUp: () => platform.promptResult = AppLockPromptResult.cancelled,
      build: () => AppLockCubit(lock),
      act: (cubit) async {
        await cubit.autoUnlock();
        await cubit.autoUnlock();
      },
      expect: () => const [
        AppLockState(status: AppLockStatus.locked, prompting: true),
        AppLockState(status: AppLockStatus.locked, failed: true),
      ],
    );

    blocTest<AppLockCubit, AppLockState>(
      'does nothing once closed',
      build: () => AppLockCubit(lock),
      act: (cubit) async {
        await cubit.close();
        await cubit.unlock();
        await cubit.autoUnlock();
        lock.configure(AppLockTimeout.off);
        await pumpEventQueue();
      },
      expect: () => const <AppLockState>[],
      verify: (_) => expect(platform.prompts, isEmpty),
    );

    blocTest<AppLockCubit, AppLockState>(
      'ignores a prompt that ends after close',
      setUp: () => platform.holdPrompt = Completer(),
      build: () => AppLockCubit(lock),
      act: (cubit) async {
        final unlocking = cubit.unlock();
        await pumpEventQueue();
        await cubit.close();
        platform.holdPrompt!.complete(AppLockPromptResult.success);
        await unlocking;
      },
      expect: () => const [
        AppLockState(status: AppLockStatus.locked, prompting: true),
      ],
    );
  });
}
