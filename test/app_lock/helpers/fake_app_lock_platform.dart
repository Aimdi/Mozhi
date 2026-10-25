import 'dart:async';

import 'package:mozhi/app_lock/data/app_lock_platform.dart';

/// An [AppLockPlatform] that behaves like `AppLockPlugin.kt` without a
/// phone: the shared state is plain fields, [setUnlocked] resets the
/// absences, and the prompt answers [promptResult] (or waits for
/// [holdPrompt]'s completer).
class FakeAppLockPlatform implements AppLockPlatform {
  new({this.secure = true, this.unlocked = false});

  bool secure;
  bool unlocked;
  Duration? longestAway;
  Duration? longestOwnTrip;
  Duration? currentAway;
  bool currentIsOwnTrip = false;
  bool inFront = true;

  /// Thrown by [session] when set.
  Exception? sessionError;

  /// When true, [session] calls wait in [pendingSessions] until completed.
  bool holdSessions = false;
  final pendingSessions = <Completer<AppLockSession>>[];

  AppLockPromptResult promptResult = AppLockPromptResult.success;

  /// Thrown by [authenticate] when set.
  Exception? promptError;

  /// When set, [authenticate] waits for it.
  Completer<AppLockPromptResult>? holdPrompt;

  final prompts = <AppLockPromptTexts>[];
  final unlockedWrites = <bool>[];
  final protections = <bool>[];
  int sessionCalls = 0;

  /// What the platform would answer now.
  AppLockSession get current => AppLockSession(
    secure: secure,
    unlocked: unlocked,
    longestAway: longestAway,
    longestOwnTrip: longestOwnTrip,
    currentAway: currentAway,
    currentIsOwnTrip: currentIsOwnTrip,
    inFront: inFront,
  );

  /// The app left the screen [away] ago ([ownTrip]: for a result).
  void leave(Duration away, {bool ownTrip = false}) {
    inFront = false;
    currentAway = away;
    currentIsOwnTrip = ownTrip;
    if (ownTrip) {
      longestOwnTrip = _max(longestOwnTrip, away);
    } else {
      longestAway = _max(longestAway, away);
    }
  }

  /// A Mozhi window is back on the screen.
  void comeBack() {
    inFront = true;
    currentAway = null;
    currentIsOwnTrip = false;
  }

  static Duration _max(Duration? a, Duration b) => a == null || b > a ? b : a;

  @override
  Future<AppLockSession> session() async {
    sessionCalls++;
    if (sessionError case final error?) throw error;
    if (holdSessions) {
      final completer = Completer<AppLockSession>();
      pendingSessions.add(completer);
      return await completer.future;
    }
    return current;
  }

  @override
  Future<void> setUnlocked({required bool unlocked}) async {
    unlockedWrites.add(unlocked);
    this.unlocked = unlocked;
    longestAway = null;
    longestOwnTrip = null;
  }

  @override
  Future<AppLockPromptResult> authenticate(AppLockPromptTexts texts) async {
    prompts.add(texts);
    if (promptError case final error?) throw error;
    if (holdPrompt case final completer?) return await completer.future;
    return promptResult;
  }

  @override
  Future<void> setProtected({required bool enabled}) async {
    protections.add(enabled);
  }
}

/// Timers that only fire when the test says so.
class FakeTimers {
  final timers = <FakeTimer>[];

  /// The timers not yet fired or cancelled.
  List<FakeTimer> get active => [
    for (final timer in timers)
      if (timer.isActive) timer,
  ];

  Timer call(Duration delay, void Function() callback) {
    final timer = FakeTimer(delay, callback);
    timers.add(timer);
    return timer;
  }

  /// Fires the only active timer.
  void fire() => active.single.fire();
}

class FakeTimer implements Timer {
  new(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  /// Runs the callback even when cancelled (a timer that was already
  /// due when it was cancelled).
  void forceFire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
