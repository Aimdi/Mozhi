import 'dart:async';

import 'package:mozhi/app_lock/data/app_lock_platform.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// The app lock: Mozhi asks for the phone's biometrics or screen lock
/// before it shows anything, at every cold start and after it was in the
/// background for the time the user chose ([AppSettings.appLock]).
///
/// The app provides it as `RepositoryProvider<AppLock>`
/// (`maybeAppLock`); the lock gate above the router (`AppLockGate`) shows
/// the lock screen while [isLocked].
abstract interface class AppLock {
  /// Whether the app's content must stay hidden: the lock is on and the
  /// app was not unlocked (or is still finding out at start). Also while
  /// a return to the app is being checked ([noteForeground]), until the
  /// platform said the app may stay unlocked: nothing should start then
  /// (the camera, a link) behind a lock that is about to engage.
  bool get isLocked;

  /// [isLocked] as it changes.
  Stream<bool> get changes;

  /// Asks for the phone's biometrics or screen lock, unless the app is not
  /// locked. True when it is unlocked afterwards; false when the prompt
  /// was cancelled or failed (the app stays locked).
  Future<bool> unlock();

  /// The app went to the background (no longer visible).
  void noteBackground();

  /// The app came back to the foreground.
  void noteForeground();
}

/// Where an [AppLockController] is.
enum AppLockStatus {
  /// Finding out whether the app is locked (at start, while the shared
  /// state of the app's windows is read): nothing is shown yet.
  checking,

  /// Locked: the lock screen shows.
  locked,

  /// Unlocked, or the lock is off.
  unlocked,
}

/// The [AppLock] of one window of the app, over an [AppLockPlatform].
///
/// The lock state is shared by every window of the app process (the
/// platform keeps it, [AppLockPlatform.session]): unlocking the quick
/// translate window unlocks the app, and the app locks again once it was
/// away from the screen for longer than the [timeout]
/// ([AppLockTimeout.immediately]: on every return). Absences are measured
/// by the platform with a monotonic clock that counts while the phone
/// sleeps, so changing the phone's clock can't get round the timeout.
/// Trips to another app that Mozhi opened for a result (the camera, a file
/// picker, saving a file) are part of using it: they lock after
/// [ownTripAllowance] or the timeout, whichever is longer.
///
/// While the app is in the background a timer locks it as soon as the
/// timeout has passed, so it comes back already locked; coming back checks
/// again ([noteForeground]): the timer may not have run while the phone
/// slept, so until the platform answered, [isLocked] is true (and
/// [changes] says so) while [status] stays unlocked (the lock gate goes on
/// showing the app rather than flash the lock screen at every return).
/// `clock` (monotonic, default a [Stopwatch]) and `timer` are for tests.
///
/// When the phone has no secure lock screen (any more), there is nothing
/// to unlock with and the app does not lock (the settings say why).
/// Platform errors while finding out keep it locked.
class AppLockController implements AppLock {
  new({
    required this._platform,
    AppLockTimeout timeout = AppLockTimeout.off,
    this._protectWindow = true,
    Duration Function()? clock,
    Timer Function(Duration delay, void Function() callback)? timer,
  }) : _timeout = timeout,
       _clock = clock ?? _stopwatch(),
       _timerFactory = timer ?? Timer.new,
       _status = timeout.isOn
           ? AppLockStatus.checking
           : AppLockStatus.unlocked {
    if (timeout.isOn) {
      _applyProtection();
      unawaited(_check());
    }
  }

  /// The least time a trip to another app that Mozhi opened for a result
  /// (camera, file picker) may take before the app locks.
  static const ownTripAllowance = Duration(minutes: 5);

  /// How often the background timer looks again when the platform could
  /// not tell.
  static const retryDelay = Duration(seconds: 30);

  /// The texts of the system prompt until the app sets its own
  /// ([promptTexts]).
  static const defaultPromptTexts = AppLockPromptTexts(
    title: 'Unlock Mozhi',
    subtitle: 'Use your fingerprint, face or screen lock',
    fallback: 'Use PIN, pattern or password',
  );

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final AppLockPlatform _platform;
  final bool _protectWindow;
  final Duration Function() _clock;
  final Timer Function(Duration, void Function()) _timerFactory;

  final _statuses = StreamController<AppLockStatus>.broadcast();
  final _changes = StreamController<bool>.broadcast();

  AppLockTimeout _timeout;
  AppLockStatus _status;

  /// Counts transitions and checks: an answer for an older one is stale.
  int _generation = 0;
  Timer? _timer;

  /// When ([_clock]) the app went to the background while unlocked; null
  /// while in the foreground.
  Duration? _awaySince;

  /// Whether the current absence is an own trip; null until the platform
  /// said.
  bool? _awayIsOwnTrip;

  Future<bool>? _prompt;

  /// The check of a return to the app ([noteForeground]) that keeps
  /// [isLocked] true until it answered, and completes then; null when none
  /// is pending.
  ({int generation, Completer<void> done})? _verifying;

  /// The app went to the background while a prompt showed (the screen
  /// lock is a screen of its own): the return that follows is not one.
  bool _hiddenDuringPrompt = false;
  bool _autoPromptDue = true;
  bool _disposed = false;

  /// The texts of the system prompt (the app sets them in its language).
  AppLockPromptTexts promptTexts = defaultPromptTexts;

  /// The texts of the prompt that confirms turning the lock on
  /// ([confirm]).
  AppLockPromptTexts? confirmTexts;

  /// When the app locks.
  AppLockTimeout get timeout => _timeout;

  AppLockStatus get status => _status;

  /// [status] as it changes.
  Stream<AppLockStatus> get statusChanges => _statuses.stream;

  /// Whether a system prompt is showing.
  bool get isPrompting => _prompt != null;

  @override
  bool get isLocked => _status != AppLockStatus.unlocked || _verifying != null;

  @override
  Stream<bool> get changes => _changes.stream;

  /// Whether the app lock can work here: the phone has a secure lock
  /// screen (never on the web). Never throws.
  Future<bool> isAvailable() async {
    try {
      return _lastKnownAvailable = (await _platform.session()).secure;
    } on Object {
      return _lastKnownAvailable = false;
    }
  }

  /// What [isAvailable] (or a check of the lock) found last; null before
  /// either asked the platform.
  bool? get lastKnownAvailable => _lastKnownAvailable;
  bool? _lastKnownAvailable;

  /// Applies the setting [timeout]. Turning the lock on keeps the app
  /// unlocked (the user just confirmed, see [confirm]); turning it off
  /// unlocks it.
  void configure(AppLockTimeout timeout) {
    if (_disposed || timeout == _timeout) return;
    final wasOn = _timeout.isOn;
    _timeout = timeout;
    if (wasOn != timeout.isOn) _applyProtection();
    if (!timeout.isOn) {
      _generation++;
      _cancelTimer();
      _awaySince = null;
      _setStatus(AppLockStatus.unlocked);
      // The platform side stops treating the app as locked (the caption
      // bar, `LiveCaptionService.kt`).
      unawaited(_quietly(() => _platform.setUnlocked(unlocked: true)));
    } else if (!wasOn && _status == AppLockStatus.unlocked) {
      unawaited(_quietly(() => _platform.setUnlocked(unlocked: true)));
    }
  }

  @override
  Future<bool> unlock() async {
    if (_disposed) return false;
    if (_status == AppLockStatus.checking) {
      await statusChanges.firstWhere(
        (s) => s != AppLockStatus.checking,
        orElse: () => AppLockStatus.checking, // Disposed meanwhile.
      );
    }
    // A return being checked: its answer decides.
    if (_verifying case final verifying?) await verifying.done.future;
    if (_disposed) return false;
    if (!isLocked) return true;
    return await _showPrompt(confirming: false);
  }

  /// Asks for the phone's biometrics or screen lock whether or not the app
  /// is locked, before the lock is turned on (so nobody locks themselves
  /// out). True when the user passed it.
  Future<bool> confirm() {
    if (_disposed) return Future.value(false);
    return _showPrompt(confirming: true);
  }

  /// Checks now whether the app was away for too long, as the background
  /// timer does when it fires, and locks it when so. The timer may fire
  /// late after the phone slept (it does not count deep sleep); what shows
  /// outside the app while it is in the background (the caption bar) asks
  /// when the phone is unlocked. Does nothing unless the app is in the
  /// background and unlocked; completes once the platform answered.
  Future<void> checkAway() async {
    if (_disposed || _awaySince == null || _status != AppLockStatus.unlocked) {
      return;
    }
    _cancelTimer();
    await _backgroundCheck();
  }

  /// Completes once the app is unlocked (at once when it is).
  Future<void> untilUnlocked() async {
    if (!isLocked) return;
    await changes.firstWhere(
      (locked) => !locked,
      orElse: () => true, // Disposed while locked.
    );
  }

  /// Whether the lock screen should open the prompt by itself now: once
  /// at start and once per return to the app, while locked. Consumes it.
  bool takeAutoPrompt() {
    if (_status != AppLockStatus.locked || !_autoPromptDue || isPrompting) {
      return false;
    }
    _autoPromptDue = false;
    return true;
  }

  @override
  void noteBackground() {
    if (_disposed) return;
    if (isPrompting) {
      _hiddenDuringPrompt = true;
      return;
    }
    if (!_timeout.isOn || _status != AppLockStatus.unlocked) return;
    _awaySince = _clock();
    _awayIsOwnTrip = null;
    _schedule(_timeout.delay!);
  }

  @override
  void noteForeground() {
    if (_disposed) return;
    if (_hiddenDuringPrompt) {
      // The screen lock's own screen went away: not a return to the app.
      _hiddenDuringPrompt = false;
      return;
    }
    _cancelTimer();
    final since = _awaySince;
    _awaySince = null;
    if (!_timeout.isOn) return;
    _autoPromptDue = true;
    if (_status == AppLockStatus.unlocked && since != null) {
      // A lower bound (the clock may stop while the phone sleeps): lock
      // right away when it already says so.
      final limit = (_awayIsOwnTrip ?? true) ? _ownTripLimit : _limit;
      if (_clock() - since >= limit) _lock();
    }
    if (_status != AppLockStatus.checking) {
      // Still unlocked: locked for what would start now until the platform
      // said (the clock may have stopped while the phone slept).
      unawaited(_check(verify: _status == AppLockStatus.unlocked));
    }
  }

  /// Stops the timer and closes the streams.
  Future<void> dispose() async {
    _disposed = true;
    _cancelTimer();
    final verifying = _verifying;
    _verifying = null;
    verifying?.done.complete();
    await _statuses.close();
    await _changes.close();
  }

  Duration get _limit => _timeout.delay ?? Duration.zero;

  Duration get _ownTripLimit =>
      _limit > ownTripAllowance ? _limit : ownTripAllowance;

  /// Whether [session] says the app was away for too long.
  bool _exceeded(AppLockSession session) {
    final away = session.longestAway;
    final ownTrip = session.longestOwnTrip;
    return (away != null && away >= _limit) ||
        (ownTrip != null && ownTrip >= _ownTripLimit);
  }

  /// Reads the shared state and locks or unlocks this window by it. With
  /// [verify] (a return while unlocked), [isLocked] is true until then.
  Future<void> _check({bool verify = false}) async {
    final generation = ++_generation;
    if (verify) _beginVerifying(generation);
    try {
      await _checkSession(generation);
    } finally {
      // Not settled by a status (an error, or a newer check overtook it).
      final verifying = _verifying;
      if (verifying != null && verifying.generation == generation) {
        _verifying = null;
        if (!isLocked) _changes.add(false);
        verifying.done.complete();
      }
    }
  }

  /// [isLocked] is true until check [generation] answered.
  void _beginVerifying(int generation) {
    final wasLocked = isLocked;
    _verifying = (
      generation: generation,
      // One that was pending ends with this one.
      done: _verifying?.done ?? Completer<void>(),
    );
    if (!wasLocked) _changes.add(true);
  }

  Future<void> _checkSession(int generation) async {
    AppLockSession? session;
    try {
      session = await _platform.session();
    } on Object {
      session = null;
    }
    if (_disposed || generation != _generation || !_timeout.isOn) return;
    if (session == null) {
      // Can't tell: keep what is shown; never show content at start.
      if (_status == AppLockStatus.checking) _setStatus(AppLockStatus.locked);
      return;
    }
    _lastKnownAvailable = session.secure;
    if (!session.secure) {
      // No screen lock to unlock with (any more).
      _setStatus(AppLockStatus.unlocked);
    } else if (!session.unlocked || _exceeded(session)) {
      _lock();
    } else {
      // Unlocked, also when another window of the app was.
      _setStatus(AppLockStatus.unlocked);
    }
  }

  /// The background timer: locks once the app was away for too long.
  Future<void> _backgroundCheck() async {
    _timer = null;
    if (_awaySince == null || _status != AppLockStatus.unlocked) return;
    final generation = ++_generation;
    AppLockSession? session;
    try {
      session = await _platform.session();
    } on Object {
      session = null;
    }
    if (_disposed || generation != _generation || _awaySince == null) return;
    if (session == null) {
      _schedule(retryDelay);
      return;
    }
    _awayIsOwnTrip = session.currentIsOwnTrip;
    if (!session.secure) return;
    if (!session.unlocked || _exceeded(session)) {
      _lock();
      return;
    }
    final current = session.currentAway;
    // Another window of the app is on the screen: it keeps watch.
    if (session.inFront || current == null) return;
    final limit = session.currentIsOwnTrip ? _ownTripLimit : _limit;
    final remaining = limit - current;
    _schedule(
      remaining > const Duration(seconds: 1)
          ? remaining
          : const Duration(seconds: 1),
    );
  }

  Future<bool> _showPrompt({required bool confirming}) =>
      _prompt ??= _runPrompt(confirming: confirming)
          .whenComplete(() => _prompt = null);

  Future<bool> _runPrompt({required bool confirming}) async {
    final texts = confirming ? confirmTexts ?? promptTexts : promptTexts;
    AppLockPromptResult result;
    try {
      result = await _platform.authenticate(texts);
    } on Object {
      result = AppLockPromptResult.error;
    }
    if (_disposed) return false;
    switch (result) {
      case AppLockPromptResult.success:
        _generation++;
        _setStatus(AppLockStatus.unlocked);
        await _quietly(() => _platform.setUnlocked(unlocked: true));
        return true;
      case AppLockPromptResult.unavailable:
        // No screen lock (any more): nothing to unlock with, nothing to
        // turn on.
        if (confirming) return false;
        _generation++;
        _setStatus(AppLockStatus.unlocked);
        return true;
      case AppLockPromptResult.cancelled:
      case AppLockPromptResult.busy:
      case AppLockPromptResult.error:
        return false;
    }
  }

  void _lock() {
    _generation++;
    _cancelTimer();
    _setStatus(AppLockStatus.locked);
    unawaited(_quietly(() => _platform.setUnlocked(unlocked: false)));
  }

  /// Sets [status]; a return being checked is settled by it.
  void _setStatus(AppLockStatus next) {
    if (_disposed) return;
    final wasLocked = isLocked;
    final verifying = _verifying;
    _verifying = null;
    if (next != _status) {
      _status = next;
      _statuses.add(next);
    }
    if (wasLocked != isLocked) _changes.add(isLocked);
    verifying?.done.complete();
  }

  void _schedule(Duration delay) {
    _cancelTimer();
    _timer = _timerFactory(delay, () => unawaited(_backgroundCheck()));
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _applyProtection() => unawaited(
    _quietly(
      () => _platform.setProtected(enabled: _protectWindow && _timeout.isOn),
    ),
  );

  static Future<void> _quietly(Future<void> Function() call) async {
    try {
      await call();
    } on Object {
      // The platform side refused; the lock itself is unaffected.
    }
  }

  @override
  String toString() => 'AppLockController($_timeout, $_status)';
}
