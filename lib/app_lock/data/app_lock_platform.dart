import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device.dart';

/// How a system unlock prompt ended ([AppLockPlatform.authenticate]).
enum AppLockPromptResult {
  /// The user passed the phone's biometrics or screen lock.
  success,

  /// The user closed the prompt (or the system did, e.g. when the app
  /// went to the background).
  cancelled,

  /// The phone has no secure lock screen (any more): there is nothing to
  /// unlock with.
  unavailable,

  /// Another prompt of this window is showing.
  busy,

  /// The prompt could not be shown or failed (too many attempts, a
  /// hardware error, ...).
  error;

  /// The result named [name] (as the platform side answers); [error] for
  /// anything else.
  static AppLockPromptResult fromName(Object? name) =>
      (name is String ? values.asNameMap()[name] : null) ?? error;
}

/// The texts of the system unlock prompt.
@immutable
class AppLockPromptTexts extends Equatable {
  const new({
    required this.title,
    required this.subtitle,
    required this.fallback,
  });

  /// "Unlock Mozhi".
  final String title;

  /// One line below the title.
  final String subtitle;

  /// The button that switches from biometrics to the PIN, pattern or
  /// password where the system does not offer it itself (Android 9).
  final String fallback;

  /// The arguments of the platform's `authenticate` call.
  Map<String, String> toMap() => {
    'title': title,
    'subtitle': subtitle,
    'fallback': fallback,
  };

  @override
  List<Object?> get props => [title, subtitle, fallback];
}

/// What the platform knows about the app lock of this app process, which
/// every Mozhi window (the main one, the quick translate window, the
/// screen-translate window) shares ([AppLockPlatform.session]).
///
/// Durations come from a monotonic clock that keeps counting while the
/// phone sleeps (Android's `SystemClock.elapsedRealtime`), so changing the
/// phone's clock changes nothing. An absence starts when the last Mozhi
/// window leaves the screen and ends when one comes back; one that starts
/// while an unlock prompt shows is not counted.
@immutable
class AppLockSession extends Equatable {
  const new({
    required this.secure,
    this.unlocked = false,
    this.longestAway,
    this.longestOwnTrip,
    this.currentAway,
    this.currentIsOwnTrip = false,
    this.inFront = true,
  });

  /// Parses the platform's answer; anything missing or invalid falls back
  /// to the safe value (locked, no screen lock known: [secure] false).
  factory fromMap(Map<Object?, Object?>? map) {
    Duration? duration(Object? value) =>
        value is int && value >= 0 ? Duration(milliseconds: value) : null;
    return AppLockSession(
      secure: map?['secure'] == true,
      unlocked: map?['unlocked'] == true,
      longestAway: duration(map?['awayMs']),
      longestOwnTrip: duration(map?['ownTripMs']),
      currentAway: duration(map?['currentMs']),
      currentIsOwnTrip: map?['currentIsOwnTrip'] == true,
      inFront: map?['inFront'] != false,
    );
  }

  /// No app lock here (no platform side, the web): nothing to unlock
  /// with.
  static const unavailable = AppLockSession(secure: false);

  /// Whether the phone has a secure lock screen (PIN, pattern, password),
  /// which the app lock needs (Android `KeyguardManager.isDeviceSecure`).
  final bool secure;

  /// Whether one of the app's windows was unlocked since the app process
  /// started and nothing locked it again ([AppLockPlatform.setUnlocked]).
  final bool unlocked;

  /// The longest time the app was away from the screen since [unlocked]
  /// was last set, the current absence included; null when it never was.
  /// Without [longestOwnTrip]s.
  final Duration? longestAway;

  /// Like [longestAway], for absences that started with Mozhi opening
  /// another app for a result (the camera, a file picker): those are part
  /// of using the app and get more time (see
  /// `AppLockController.ownTripAllowance`).
  final Duration? longestOwnTrip;

  /// How long the current absence has lasted; null while a Mozhi window
  /// is on the screen.
  final Duration? currentAway;

  /// Whether the current absence is an own trip (see [longestOwnTrip]).
  final bool currentIsOwnTrip;

  /// Whether a Mozhi window is on the screen (started).
  final bool inFront;

  @override
  List<Object?> get props => [
    secure,
    unlocked,
    longestAway,
    longestOwnTrip,
    currentAway,
    currentIsOwnTrip,
    inFront,
  ];
}

/// The platform side of the app lock: the system unlock prompt, the shared
/// lock state of the app process and keeping the window out of Recents.
abstract interface class AppLockPlatform {
  /// The shared state ([AppLockSession.unavailable] without a platform
  /// side). May throw a [PlatformException].
  Future<AppLockSession> session();

  /// Records whether the app is unlocked, for every window of the
  /// process, and starts counting absences anew.
  Future<void> setUnlocked({required bool unlocked});

  /// Shows the system prompt (biometrics, or the PIN, pattern or password).
  Future<AppLockPromptResult> authenticate(AppLockPromptTexts texts);

  /// Keeps this window's content out of Recents ([enabled]) or lets it
  /// show again: on Android 13+ without a screenshot in Recents, on older
  /// versions with `FLAG_SECURE` (which also blocks screenshots), together
  /// with the "Hide content in recents" setting.
  Future<void> setProtected({required bool enabled});
}

/// [AppLockPlatform] where there is none (the web, tests on a desktop
/// host): never secure, so the app never locks.
class UnavailableAppLockPlatform implements AppLockPlatform {
  const new();

  @override
  Future<AppLockSession> session() async => AppLockSession.unavailable;

  @override
  Future<void> setUnlocked({required bool unlocked}) async {}

  @override
  Future<AppLockPromptResult> authenticate(AppLockPromptTexts texts) async =>
      AppLockPromptResult.unavailable;

  @override
  Future<void> setProtected({required bool enabled}) async {}
}

/// The Android [AppLockPlatform]: `AppLockPlugin.kt`, method channel
/// [channelName].
///
/// * `session()` -> `{secure, unlocked, awayMs, ownTripMs, currentMs,
///   currentIsOwnTrip, inFront}` (durations in milliseconds, -1 for none),
///   see [AppLockSession].
/// * `setUnlocked(Boolean)`.
/// * `authenticate({title, subtitle, fallback})` -> the name of an
///   [AppLockPromptResult]: the framework `BiometricPrompt` (Android 9+;
///   biometrics or the screen lock on 10+), else the screen lock
///   (`KeyguardManager.createConfirmDeviceCredentialIntent`).
/// * `setProtected(Boolean)`: `Activity.setRecentsScreenshotEnabled` on
///   Android 13+, `FLAG_SECURE` before.
///
/// Without the platform side ([MissingPluginException]) it behaves like
/// [UnavailableAppLockPlatform]; other errors are thrown.
class MethodChannelAppLockPlatform implements AppLockPlatform {
  new({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.aimdi.mozhi/app_lock';

  final MethodChannel _channel;

  @override
  Future<AppLockSession> session() async {
    try {
      return AppLockSession.fromMap(
        await _channel.invokeMethod<Map<Object?, Object?>>('session'),
      );
    } on MissingPluginException {
      return AppLockSession.unavailable;
    }
  }

  @override
  Future<void> setUnlocked({required bool unlocked}) =>
      _invoke('setUnlocked', unlocked);

  @override
  Future<AppLockPromptResult> authenticate(AppLockPromptTexts texts) async {
    try {
      return AppLockPromptResult.fromName(
        await _channel.invokeMethod<String>('authenticate', texts.toMap()),
      );
    } on MissingPluginException {
      return AppLockPromptResult.unavailable;
    }
  }

  @override
  Future<void> setProtected({required bool enabled}) =>
      _invoke('setProtected', enabled);

  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No platform side: nothing to record.
    }
  }
}

/// The [AppLockPlatform] of this platform: [MethodChannelAppLockPlatform]
/// on Android ([isAndroid], default [runsOnAndroid]), else
/// [UnavailableAppLockPlatform] (the web, other hosts).
AppLockPlatform createAppLockPlatform({bool? isAndroid}) =>
    !kIsWeb && (isAndroid ?? runsOnAndroid)
    ? MethodChannelAppLockPlatform()
    : const UnavailableAppLockPlatform();
