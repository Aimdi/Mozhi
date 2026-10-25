import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device.dart';

/// What the platform says about "Translate screen" and the bubble
/// ([ScreenTranslateControls.status]).
@immutable
class ScreenTranslateSupport {
  const new({
    this.bubbleRunning = false,
    this.canDrawOverlays = false,
    this.notificationsAllowed = true,
    this.canAddTile = false,
  });

  /// Whether the bubble is on (its service runs).
  final bool bubbleRunning;

  /// Whether "Display over other apps" is allowed.
  final bool canDrawOverlays;

  /// Whether notifications may be shown (always before Android 13).
  final bool notificationsAllowed;

  /// Whether the app can offer its Quick Settings tile (Android 13+).
  final bool canAddTile;

  @override
  bool operator ==(Object other) =>
      other is ScreenTranslateSupport &&
      other.bubbleRunning == bubbleRunning &&
      other.canDrawOverlays == canDrawOverlays &&
      other.notificationsAllowed == notificationsAllowed &&
      other.canAddTile == canAddTile;

  @override
  int get hashCode => Object.hash(
    bubbleRunning,
    canDrawOverlays,
    notificationsAllowed,
    canAddTile,
  );

  @override
  String toString() =>
      'ScreenTranslateSupport(bubble: $bubbleRunning, overlays: '
      '$canDrawOverlays, notifications: $notificationsAllowed, tile: '
      '$canAddTile)';
}

/// How offering the Quick Settings tile ended
/// ([ScreenTranslateControls.requestAddTile]).
enum TileRequestResult {
  added,
  alreadyAdded,

  /// The user said no.
  notAdded,

  /// Not before Android 13 (or no system support).
  unsupported,
  failed;

  /// The result named [value] by the platform; [failed] for anything else.
  static TileRequestResult parse(String? value) => switch (value) {
    'added' => added,
    'alreadyAdded' => alreadyAdded,
    'notAdded' => notAdded,
    'unsupported' => unsupported,
    _ => failed,
  };
}

/// The Android side of the "Translate screen" settings: the bubble (on or
/// off, its two permissions) and the Quick Settings tile. The state lives
/// natively (the bubble's service runs or not); nothing is stored in the
/// app's settings.
abstract interface class ScreenTranslateControls {
  /// Whether the feature exists here (the Android app).
  bool get isSupported;

  Future<ScreenTranslateSupport> status();

  /// Opens Android's "Display over other apps" page for Mozhi; true when
  /// it is allowed once the user is back.
  Future<bool> requestOverlayPermission();

  /// Asks for notifications (Android 13+); true when allowed or not
  /// needed.
  Future<bool> requestNotificationPermission();

  /// Starts the bubble; false without "Display over other apps" or when
  /// Android refuses.
  Future<bool> startBubble();

  Future<void> stopBubble();

  /// Offers the "Translate screen" tile for Quick Settings.
  Future<TileRequestResult> requestAddTile();
}

/// [ScreenTranslateControls] over the method channel [channelName]
/// (`ScreenTranslatePlugin.kt`, registered in every window). Unsupported
/// off Android (`isAndroid`, default [runsOnAndroid]): then nothing is
/// called and everything answers "off". Platform errors count as "no".
class MethodChannelScreenTranslateControls implements ScreenTranslateControls {
  new({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel(channelName),
      _isAndroid = isAndroid ?? runsOnAndroid;

  static const channelName = 'io.github.aimdi.mozhi/screen_translate_controls';

  /// The controls of this app.
  static ScreenTranslateControls instance =
      MethodChannelScreenTranslateControls();

  final MethodChannel _channel;
  final bool _isAndroid;

  @override
  bool get isSupported => !kIsWeb && _isAndroid;

  @override
  Future<ScreenTranslateSupport> status() async {
    if (!isSupported) return const ScreenTranslateSupport();
    final Map<String, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<String, Object?>('status');
    } on MissingPluginException {
      return const ScreenTranslateSupport();
    } on PlatformException {
      return const ScreenTranslateSupport();
    }
    if (answer == null) return const ScreenTranslateSupport();
    return ScreenTranslateSupport(
      bubbleRunning: answer['bubbleRunning'] == true,
      canDrawOverlays: answer['canDrawOverlays'] == true,
      notificationsAllowed: answer['notificationsAllowed'] != false,
      canAddTile: answer['canAddTile'] == true,
    );
  }

  @override
  Future<bool> requestOverlayPermission() => _ask('requestOverlayPermission');

  @override
  Future<bool> requestNotificationPermission() =>
      _ask('requestNotificationPermission');

  @override
  Future<bool> startBubble() => _ask('startBubble');

  @override
  Future<void> stopBubble() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopBubble');
    } on MissingPluginException {
      // Nothing to stop.
    } on PlatformException {
      // Nothing to stop.
    }
  }

  @override
  Future<TileRequestResult> requestAddTile() async {
    if (!isSupported) return TileRequestResult.unsupported;
    try {
      return TileRequestResult.parse(
        await _channel.invokeMethod<String>('requestAddTile'),
      );
    } on MissingPluginException {
      return TileRequestResult.unsupported;
    } on PlatformException {
      return TileRequestResult.failed;
    }
  }

  Future<bool> _ask(String method) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
