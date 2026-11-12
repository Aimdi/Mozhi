import 'package:equatable/equatable.dart';
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

  /// Whether Mozhi itself may use the network, as Android reports it
  /// (`networkAccess` on the privacy channel, `MainActivity.kt`): its
  /// `INTERNET` permission (GrapheneOS lets the user turn it off), whether
  /// it has an active network with internet, and whether the system blocks
  /// its traffic (a VPN in lockdown mode while the VPN is down). Asks the
  /// system only; nothing is sent. Null off Android or when it cannot tell
  /// (an older platform side, an error). Never throws.
  Future<NetworkAccess?> networkAccess() async {
    if (!_isAndroid) return null;
    try {
      final answer = await _channel.invokeMapMethod<String, Object?>(
        'networkAccess',
      );
      if (answer == null) return null;
      return NetworkAccess(
        internetPermission: answer['internetPermission'] != false,
        hasNetwork: answer['hasNetwork'] != false,
        blocked: answer['blocked'] == true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// What Android says about Mozhi's own access to the network
/// ([MeteredNetwork.networkAccess]).
class NetworkAccess extends Equatable {
  const new({
    required this.internetPermission,
    required this.hasNetwork,
    required this.blocked,
  });

  /// Mozhi has the `INTERNET` permission (false when the user turned off
  /// its Network permission on GrapheneOS).
  final bool internetPermission;

  /// Mozhi's active network exists and reaches the internet.
  final bool hasNetwork;

  /// The system blocks Mozhi's traffic on its network.
  final bool blocked;

  /// The app was denied the network itself, whatever the device's
  /// connection: the permission is off or the system blocks it.
  bool get denied => !internetPermission || blocked;

  /// Mozhi can send requests.
  bool get usable => internetPermission && hasNetwork && !blocked;

  @override
  List<Object?> get props => [internetPermission, hasNetwork, blocked];
}
