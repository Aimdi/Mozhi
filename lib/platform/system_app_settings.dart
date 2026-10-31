import 'package:flutter/foundation.dart';
import 'package:mozhi/live_camera/data/method_channel_live_camera_controller.dart';
import 'package:mozhi/platform/android_device.dart';

/// Opens Mozhi's page in Android's settings (App info), where a permission
/// that Android no longer asks for ("Don't allow" twice, or "Don't ask
/// again") can still be granted: the camera for "Take photo", the
/// microphone for live captions.
///
/// It goes through `LiveCameraPlugin.kt` (`openAppSettings` on
/// [MethodChannelLiveCameraController.channelName]), which every window
/// registers.
abstract final class SystemAppSettings {
  /// Whether this platform has such a page ([runsOnAndroid]; never in the
  /// web app).
  static bool get isSupported => debugIsSupported ?? runsOnAndroid;

  /// Replaces [isSupported] in tests.
  @visibleForTesting
  static bool? debugIsSupported;

  /// Opens the page; false when it could not be opened. Never throws.
  /// Replaceable in tests.
  @visibleForTesting
  static Future<bool> Function() opener = _open;

  static Future<bool> _open() =>
      MethodChannelLiveCameraController().openAppSettings();

  /// Opens the page ([opener]); false when it could not be opened or
  /// [isSupported] is false. Never throws.
  static Future<bool> open() async {
    if (!isSupported) return false;
    try {
      return await opener();
    } on Object {
      return false;
    }
  }
}
