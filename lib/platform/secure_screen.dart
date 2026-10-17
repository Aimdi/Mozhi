import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/platform/privacy_channel.dart';

/// Hides the app's content in the recent apps screen and blocks
/// screenshots and screen recording (Android `FLAG_SECURE`).
///
/// Only Android has it ([isSupported]); elsewhere, and when the platform
/// side is missing, [setEnabled] does nothing.
class SecureScreen {
  new({MethodChannel? channel, bool? isSupported})
    : _channel = channel ?? privacyChannel(),
      isSupported = isSupported ?? _android;

  /// Used by `SecureScreenListener` unless it is given another one.
  static SecureScreen instance = SecureScreen();

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;

  /// Whether this platform can protect the screen (Android).
  final bool isSupported;

  /// Sets (`true`) or clears `FLAG_SECURE` on the app's window. Never
  /// throws.
  Future<void> setEnabled({required bool enabled}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setSecureScreen', enabled);
    } on MissingPluginException {
      // No platform side (tests, other embedders).
    } on PlatformException {
      // The window refused it; nothing else to do.
    }
  }
}
