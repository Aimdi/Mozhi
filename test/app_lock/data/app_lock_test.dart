import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/app_lock/data/app_lock_platform.dart';
import 'package:mozhi/settings/models/app_settings.dart';

import '../helpers/fake_app_lock_platform.dart';

void main() {
  late FakeAppLockPlatform platform;
  late FakeTimers timers;
  late Duration now;

  setUp(() {
    platform = FakeAppLockPlatform();
    timers = FakeTimers();
    now = Duration.zero;
  });

  AppLockController create({
    AppLockTimeout timeout = AppLockTimeout.after1Minute,
    bool protectWindow = true,
  }) {
    final lock = AppLockController(
      platform: platform,
      timeout: timeout,
      protectWindow: protectWindow,
      clock: () => now,
      timer: timers.call,
    );
    addTearDown(lock.dispose);
    return lock;
  }

  /// A lock that is on and unlocked (as after the start prompt).
  Future<AppLockController> unlocked({
    AppLockTimeout timeout = AppLockTimeout.after1Minute,
  }) async {
    platform.unlocked = true;
    final lock = create(timeout: timeout);
    await pumpEventQueue();
    expect(lock.status, AppLockStatus.unlocked);
    return lock;
  }

  group('when off', () {
    test('is unlocked from the start and asks the platform nothing', () async {
      final lock = create(timeout: AppLockTimeout.off);
      await pumpEventQueue();

      expect(lock.status, AppLockStatus.unlocked);
      expect(lock.isLocked, isFalse);
      expect(lock.timeout, AppLockTimeout.off);
      expect(platform.sessionCalls, 0);
      expect(platform.protections, isEmpty);
    });

    test('never locks in the background', () async {
      final lock = create(timeout: AppLockTimeout.off)..noteBackground();
      now = const Duration(hours: 1);
      lock.noteForeground();
      await pumpEventQueue();

      expect(timers.timers, isEmpty);
      expect(lock.isLocked, isFalse);
      expect(platform.sessionCalls, 0);
    });

    test('unlock succeeds without a prompt', () async {
      final lock = create(timeout: AppLockTimeout.off);

      expect(await lock.unlock(), isTrue);
      expect(platform.prompts, isEmpty);
    });
  });

  group('at start', () {
    test('is checking, then locked in a new app process', () async {
      final lock = create();
      final statuses = <AppLockStatus>[];
      lock.statusChanges.listen(statuses.add);

      expect(lock.status, AppLockStatus.checking);
      expect(lock.isLocked, isTrue);
      await pumpEventQueue();

      expect(lock.status, AppLockStatus.locked);
      expect(statuses, [AppLockStatus.locked]);
      expect(platform.unlockedWrites, [false]);
    });

    test('is unlocked when another window unlocked the app '
        'within the timeout', () async {
      platform
        ..unlocked = true
        ..longestAway = const Duration(seconds: 30);
      final lock = create();
      final changes = <bool>[];
      lock.changes.listen(changes.add);
      await pumpEventQueue();

      expect(lock.status, AppLockStatus.unlocked);
      expect(changes, [false]);
    });

    test('is locked when the app was away for the timeout', () async {
      platform
        ..unlocked = true
        ..longestAway = const Duration(minutes: 1);
      final lock = create();
      await pumpEventQueue();

      expect(lock.status, AppLockStatus.locked);
    });

    test('is unlocked when the phone has no screen lock', () async {
      platform.secure = false;
      final lock = create();
      await pumpEventQueue();

      expect(lock.status, AppLockStatus.unlocked);
    });

    test('stays locked when the platform fails', () async {
      platform.sessionError = PlatformException(code: 'boom');
      final lock = create();
      await pumpEventQueue();

      expect(lock.status, AppLockStatus.locked);
    });

    test('keeps the main window out of Recents', () {
      create();
      expect(platform.protections, [true]);
    });

    test('leaves the other windows alone', () {
      create(protectWindow: false);
      expect(platform.protections, [false]);
    });
  });

  group('unlock', () {
    test('prompts and unlocks the app for every window', () async {
      final lock = create();
      await pumpEventQueue();
      final changes = <bool>[];
      lock.changes.listen(changes.add);

      expect(await lock.unlock(), isTrue);

      expect(lock.status, AppLockStatus.unlocked);
      expect(changes, [false]);
      expect(platform.prompts, [AppLockController.defaultPromptTexts]);
      expect(platform.unlockedWrites, [false, true]);
    });

    test('uses the prompt texts it was given', () async {
      const texts = AppLockPromptTexts(
        title: 'Mozhi entsperren',
        subtitle: 'Fingerabdruck',
        fallback: 'PIN',
      );
      final lock = create()..promptTexts = texts;
      await pumpEventQueue();

      await lock.unlock();

      expect(platform.prompts, [texts]);
    });

    for (final result in [
      AppLockPromptResult.cancelled,
      AppLockPromptResult.busy,
      AppLockPromptResult.error,
    ]) {
      test('stays locked when the prompt ends ${result.name}', () async {
        platform.promptResult = result;
        final lock = create();
        await pumpEventQueue();

        expect(await lock.unlock(), isFalse);
        expect(lock.status, AppLockStatus.locked);
        expect(platform.unlockedWrites, [false]);
      });
    }

    test('stays locked when the prompt throws', () async {
      platform.promptError = PlatformException(code: 'boom');
      final lock = create();
      await pumpEventQueue();

      expect(await lock.unlock(), isFalse);
      expect(lock.isLocked, isTrue);
    });

    test('unlocks when the phone no longer has a screen lock', () async {
      platform.promptResult = AppLockPromptResult.unavailable;
      final lock = create();
      await pumpEventQueue();

      expect(await lock.unlock(), isTrue);
      expect(lock.isLocked, isFalse);
    });

    test('waits for the start check, and needs no prompt when the app '
        'was unlocked', () async {
      platform
        ..unlocked = true
        ..holdSessions = true;
      final lock = create();
      final unlocking = lock.unlock();
      await pumpEventQueue();
      platform.pendingSessions.single.complete(platform.current);

      expect(await unlocking, isTrue);
      expect(platform.prompts, isEmpty);
    });

    test('shows one prompt for calls at the same time', () async {
      platform.holdPrompt = Completer();
      final lock = create();
      await pumpEventQueue();

      final first = lock.unlock();
      final second = lock.unlock();
      await pumpEventQueue();
      expect(lock.isPrompting, isTrue);
      platform.holdPrompt!.complete(AppLockPromptResult.success);

      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(platform.prompts, hasLength(1));
      expect(lock.isPrompting, isFalse);
    });

    test('fails after dispose', () async {
      final lock = create();
      await pumpEventQueue();
      await lock.dispose();

      expect(await lock.unlock(), isFalse);
    });

    test('fails when disposed during the start check', () async {
      platform.holdSessions = true;
      final lock = create();
      final unlocking = lock.unlock();
      await pumpEventQueue();
      await lock.dispose();

      expect(await unlocking, isFalse);
    });

    test('ignores the answer of a prompt that ends after dispose', () async {
      platform.holdPrompt = Completer();
      final lock = create();
      await pumpEventQueue();
      final unlocking = lock.unlock();
      await pumpEventQueue();
      await lock.dispose();
      platform.holdPrompt!.complete(AppLockPromptResult.success);

      expect(await unlocking, isFalse);
    });
  });

  group('confirm', () {
    test('prompts while unlocked, with the confirm texts', () async {
      const texts = AppLockPromptTexts(
        title: 'Turn on app lock',
        subtitle: 'Confirm',
        fallback: 'PIN',
      );
      final lock = create(timeout: AppLockTimeout.off)..confirmTexts = texts;

      expect(await lock.confirm(), isTrue);
      expect(platform.prompts, [texts]);
      expect(platform.unlockedWrites, [true]);
    });

    test('uses the prompt texts without confirm texts', () async {
      final lock = create(timeout: AppLockTimeout.off);

      await lock.confirm();

      expect(platform.prompts, [AppLockController.defaultPromptTexts]);
    });

    test('fails without a screen lock to confirm with', () async {
      platform.promptResult = AppLockPromptResult.unavailable;
      final lock = create(timeout: AppLockTimeout.off);

      expect(await lock.confirm(), isFalse);
    });

    test('fails when cancelled', () async {
      platform.promptResult = AppLockPromptResult.cancelled;
      final lock = create(timeout: AppLockTimeout.off);

      expect(await lock.confirm(), isFalse);
      expect(platform.unlockedWrites, isEmpty);
    });

    test('fails after dispose', () async {
      final lock = create(timeout: AppLockTimeout.off);
      await lock.dispose();

      expect(await lock.confirm(), isFalse);
      expect(platform.prompts, isEmpty);
    });
  });

  group('configure', () {
    test('turning it on keeps the app unlocked', () async {
      final lock = create(timeout: AppLockTimeout.off)
        ..configure(AppLockTimeout.immediately);
      await pumpEventQueue();

      expect(lock.timeout, AppLockTimeout.immediately);
      expect(lock.isLocked, isFalse);
      expect(platform.unlockedWrites, [true]);
      expect(platform.protections, [true]);
    });

    test('turning it off unlocks and stops the timer', () async {
      final lock = await unlocked()
        ..noteBackground();
      expect(timers.active, hasLength(1));

      lock.configure(AppLockTimeout.off);

      expect(timers.active, isEmpty);
      expect(lock.isLocked, isFalse);
      expect(platform.protections, [true, false]);
    });

    test('turning it off unlocks a locked window', () async {
      final lock = create();
      await pumpEventQueue();
      expect(lock.isLocked, isTrue);

      lock.configure(AppLockTimeout.off);

      expect(lock.isLocked, isFalse);
    });

    test('changing the time keeps the state', () async {
      final lock = await unlocked()
        ..configure(AppLockTimeout.after15Minutes);

      expect(lock.timeout, AppLockTimeout.after15Minutes);
      expect(lock.isLocked, isFalse);
      expect(platform.protections, [true]);
    });

    test('the same timeout changes nothing', () async {
      final lock = await unlocked()
        ..configure(AppLockTimeout.after1Minute);

      expect(platform.protections, [true]);
      expect(lock.isLocked, isFalse);
    });

    test('ignores the start check once turned off', () async {
      platform.holdSessions = true;
      final lock = create()..configure(AppLockTimeout.off);
      await pumpEventQueue();
      platform.pendingSessions.single.complete(platform.current);
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
    });
  });

  group('in the background', () {
    test('locks once the timeout passed', () async {
      final lock = await unlocked()
        ..noteBackground();
      final timer = timers.active.single;
      expect(timer.delay, const Duration(minutes: 1));

      platform.leave(const Duration(minutes: 1));
      timer.fire();
      await pumpEventQueue();

      expect(lock.status, AppLockStatus.locked);
      expect(platform.unlockedWrites, [false]);
    });

    test('locks right away with immediately', () async {
      final lock = await unlocked(timeout: AppLockTimeout.immediately)
        ..noteBackground();
      expect(timers.active.single.delay, Duration.zero);

      platform.leave(Duration.zero);
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isTrue);
    });

    test('gives a trip to the camera or a file picker more time', () async {
      final lock = await unlocked(timeout: AppLockTimeout.immediately)
        ..noteBackground();

      platform.leave(const Duration(seconds: 10), ownTrip: true);
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
      expect(
        timers.active.single.delay,
        AppLockController.ownTripAllowance - const Duration(seconds: 10),
      );

      platform.leave(AppLockController.ownTripAllowance, ownTrip: true);
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isTrue);
    });

    test('a long timeout counts for own trips too', () async {
      final lock = await unlocked(timeout: AppLockTimeout.after15Minutes)
        ..noteBackground();

      platform.leave(const Duration(minutes: 10), ownTrip: true);
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
      expect(timers.active.single.delay, const Duration(minutes: 5));
    });

    test('looks again later while the time is not up', () async {
      final lock = await unlocked()
        ..noteBackground();

      // The clock stopped while the phone slept: not a minute yet.
      platform.leave(const Duration(seconds: 59, milliseconds: 500));
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
      expect(timers.active.single.delay, const Duration(seconds: 1));
    });

    test('leaves the watch to a window that is on the screen', () async {
      final lock = await unlocked()
        ..noteBackground();

      platform.inFront = true;
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
      expect(timers.active, isEmpty);
    });

    test('tries again when the platform fails', () async {
      final lock = await unlocked()
        ..noteBackground();

      platform.sessionError = PlatformException(code: 'boom');
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
      expect(timers.active.single.delay, AppLockController.retryDelay);
    });

    test('locks when another window locked the app', () async {
      final lock = await unlocked()
        ..noteBackground();

      platform
        ..unlocked = false
        ..leave(const Duration(seconds: 5));
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isTrue);
    });

    test('does not lock without a screen lock', () async {
      final lock = await unlocked()
        ..noteBackground();

      platform
        ..secure = false
        ..leave(const Duration(hours: 1));
      timers.fire();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
    });

    test('needs no timer while locked', () async {
      final lock = create();
      await pumpEventQueue();

      lock.noteBackground();

      expect(timers.timers, isEmpty);
    });

    test('ignores an answer that comes after the return', () async {
      final lock = await unlocked()
        ..noteBackground();
      platform.holdSessions = true;
      timers.fire();
      await pumpEventQueue();

      lock.noteForeground();
      await pumpEventQueue();
      expect(platform.pendingSessions, hasLength(2));
      platform
        ..leave(const Duration(minutes: 5))
        ..comeBack();
      // The background check's (stale) answer: ignored.
      platform.pendingSessions.first.complete(platform.current);
      await pumpEventQueue();
      expect(lock.isLocked, isFalse);

      // The return's own check decides.
      platform.pendingSessions.last.complete(platform.current);
      await pumpEventQueue();
      expect(lock.isLocked, isTrue);
    });

    test('a timer that fires after the return does nothing', () async {
      final lock = await unlocked()
        ..noteBackground();
      final timer = timers.active.single;
      lock.noteForeground();
      await pumpEventQueue();
      final calls = platform.sessionCalls;

      timer.forceFire();
      await pumpEventQueue();

      expect(platform.sessionCalls, calls);
    });
  });

  group('coming back', () {
    test('locks at once when the clock says the time is up', () async {
      final lock = await unlocked()
        ..noteBackground();
      platform.holdSessions = true;
      timers.fire();
      await pumpEventQueue();
      platform.pendingSessions.single.complete(platform.current);
      await pumpEventQueue();
      expect(lock.isLocked, isFalse);

      now = const Duration(minutes: 2);
      lock.noteForeground();

      // Before the platform answers.
      expect(lock.isLocked, isTrue);
      expect(timers.active, isEmpty);
    });

    test('allows own trips their time before the platform said', () async {
      final lock = await unlocked()
        ..noteBackground();
      now = const Duration(minutes: 2);
      platform
        ..leave(const Duration(minutes: 2), ownTrip: true)
        ..comeBack();

      lock.noteForeground();
      expect(lock.isLocked, isFalse);
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
    });

    test('locks when the platform says the time is up', () async {
      final lock = await unlocked()
        ..noteBackground();
      // The phone slept: the clock here barely moved.
      now = const Duration(seconds: 3);
      platform
        ..leave(const Duration(minutes: 3))
        ..comeBack();

      lock.noteForeground();
      expect(lock.isLocked, isFalse);
      await pumpEventQueue();

      expect(lock.isLocked, isTrue);
    });

    test('stays unlocked within the timeout', () async {
      final lock = await unlocked()
        ..noteBackground();
      now = const Duration(seconds: 20);
      platform
        ..leave(const Duration(seconds: 20))
        ..comeBack();

      lock.noteForeground();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
    });

    test('unlocks when another window unlocked the app', () async {
      final lock = create();
      await pumpEventQueue();
      expect(lock.isLocked, isTrue);

      // The quick translate window was unlocked meanwhile.
      platform.unlocked = true;
      lock.noteForeground();
      await pumpEventQueue();

      expect(lock.isLocked, isFalse);
    });

    test('does nothing while it is still checking', () async {
      platform.holdSessions = true;
      final lock = create()..noteForeground();
      await pumpEventQueue();

      expect(platform.pendingSessions, hasLength(1));
      expect(lock.status, AppLockStatus.checking);
    });
  });

  group('the screen lock of its own screen', () {
    test('is no return to the app', () async {
      platform.holdPrompt = Completer();
      final lock = create();
      await pumpEventQueue();
      expect(lock.takeAutoPrompt(), isTrue);
      final unlocking = lock.unlock();
      await pumpEventQueue();

      lock.noteBackground();
      platform.holdPrompt!.complete(AppLockPromptResult.cancelled);
      expect(await unlocking, isFalse);
      final calls = platform.sessionCalls;
      lock.noteForeground();
      await pumpEventQueue();

      expect(platform.sessionCalls, calls);
      expect(lock.takeAutoPrompt(), isFalse, reason: 'no prompt loop');

      // The next return is one.
      lock.noteForeground();
      expect(lock.takeAutoPrompt(), isTrue);
    });

    test('is no return while the prompt still shows either', () async {
      platform.holdPrompt = Completer();
      final lock = create();
      await pumpEventQueue();
      final unlocking = lock.unlock();
      await pumpEventQueue();

      lock
        ..noteBackground()
        ..noteForeground();
      platform.holdPrompt!.complete(AppLockPromptResult.success);

      expect(await unlocking, isTrue);
      expect(lock.isLocked, isFalse);
      expect(timers.timers, isEmpty);
    });
  });

  group('takeAutoPrompt', () {
    test('is due once at start and once per return while locked', () async {
      final lock = create();
      expect(lock.takeAutoPrompt(), isFalse, reason: 'still checking');
      await pumpEventQueue();

      expect(lock.takeAutoPrompt(), isTrue);
      expect(lock.takeAutoPrompt(), isFalse);

      lock
        ..noteBackground()
        ..noteForeground();
      expect(lock.takeAutoPrompt(), isTrue);
    });

    test('is never due while unlocked', () async {
      final lock = await unlocked();

      expect(lock.takeAutoPrompt(), isFalse);
    });

    test('is not due while a prompt shows', () async {
      platform.holdPrompt = Completer();
      final lock = create();
      await pumpEventQueue();
      unawaited(lock.unlock());
      await pumpEventQueue();

      expect(lock.takeAutoPrompt(), isFalse);
      platform.holdPrompt!.complete(AppLockPromptResult.cancelled);
    });
  });

  group('untilUnlocked', () {
    test('completes at once while unlocked', () async {
      final lock = await unlocked();

      await expectLater(lock.untilUnlocked(), completes);
    });

    test('completes once unlocked', () async {
      final lock = create();
      await pumpEventQueue();
      var done = false;
      unawaited(lock.untilUnlocked().then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse);

      await lock.unlock();
      await pumpEventQueue();

      expect(done, isTrue);
    });

    test('completes when disposed while locked', () async {
      final lock = create();
      await pumpEventQueue();
      final waiting = lock.untilUnlocked();

      await lock.dispose();

      await expectLater(waiting, completes);
    });
  });

  group('isAvailable', () {
    test('is whether the phone has a screen lock', () async {
      final lock = create(timeout: AppLockTimeout.off);
      expect(await lock.isAvailable(), isTrue);

      platform.secure = false;
      expect(await lock.isAvailable(), isFalse);
    });

    test('is false when the platform fails', () async {
      platform.sessionError = PlatformException(code: 'boom');
      final lock = create(timeout: AppLockTimeout.off);

      expect(await lock.isAvailable(), isFalse);
      expect(lock.lastKnownAvailable, isFalse);
    });

    test('is remembered, also from the checks of the lock', () async {
      final off = create(timeout: AppLockTimeout.off);
      expect(off.lastKnownAvailable, isNull);
      await off.isAvailable();
      expect(off.lastKnownAvailable, isTrue);

      platform.secure = false;
      final on = create();
      await pumpEventQueue();
      expect(on.lastKnownAvailable, isFalse);
    });
  });

  test('does nothing after dispose', () async {
    final lock = await unlocked();
    await lock.dispose();

    lock
      ..noteBackground()
      ..noteForeground()
      ..configure(AppLockTimeout.off);

    expect(timers.timers, isEmpty);
    expect(lock.timeout, AppLockTimeout.after1Minute);
  });

  test('defaults to a stopwatch and real timers', () async {
    platform.unlocked = true;
    final lock = AppLockController(
      platform: platform,
      timeout: AppLockTimeout.after15Minutes,
    );
    addTearDown(lock.dispose);
    await pumpEventQueue();

    lock
      ..noteBackground()
      ..noteForeground();
    await pumpEventQueue();

    expect(lock.isLocked, isFalse);
  });

  test('describes itself', () {
    expect(
      create(timeout: AppLockTimeout.off).toString(),
      'AppLockController(AppLockTimeout.off, AppLockStatus.unlocked)',
    );
  });
}
