import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/privacy_channel.dart';

/// Whether the active network is metered (mobile data, a hotspot or a
/// Wi-Fi network marked as metered), so large downloads should ask first.
///
/// Android answers through `ConnectivityManager.isActiveNetworkMetered()`
/// (`MainActivity.kt`). When it cannot tell (no platform side, an error),
/// the network counts as metered, so nothing large is downloaded over
/// mobile data by mistake. Other platforms (desktop tests) report
/// unmetered; the web has no offline downloads at all.
class MeteredNetwork {
  new({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? privacyChannel(),
      _isAndroid = isAndroid ?? runsOnAndroid;

  /// Used by the offline engine (`offline_engine_io.dart`).
  static MeteredNetwork instance = MeteredNetwork();

  final MethodChannel _channel;
  final bool _isAndroid;

  /// See the class docs. Never throws.
  Future<bool> isMetered() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isActiveNetworkMetered') ??
          true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }
}
