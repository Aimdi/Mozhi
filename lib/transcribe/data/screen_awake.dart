import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/platform/privacy_channel.dart';
import 'package:mozhi/transcribe/data/screen_wake_lock.dart';

/// Keeps the screen on while Transcribe listens: on Android the window's
/// `FLAG_KEEP_SCREEN_ON` (method `setKeepScreenOn(Boolean)` of the
/// privacy channel), in the web app the browser's screen wake lock.
/// Never throws; where neither exists (tests, an older platform side)
/// nothing happens.
class ScreenAwake {
  new({MethodChannel? channel, bool? isWeb, WebWakeLock? webLock})
    : _channel = channel ?? privacyChannel(),
      _isWeb = isWeb ?? kIsWeb,
      _webLock = webLock ?? const WebWakeLock();

  final MethodChannel _channel;
  final bool _isWeb;
  final WebWakeLock _webLock;

  /// Keeps the screen on ([enabled]) or lets it turn off again.
  Future<void> setEnabled({required bool enabled}) async {
    try {
      if (_isWeb) {
        await (enabled ? _webLock.acquire() : _webLock.release());
      } else {
        await _channel.invokeMethod<void>('setKeepScreenOn', enabled);
      }
    } on MissingPluginException {
      // No platform side (tests) or not implemented there.
    } on PlatformException {
      // The window refused it; nothing else to do.
    } on Object {
      // The browser refused the wake lock (hidden page, no permission).
    }
  }
}
