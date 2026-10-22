import 'package:flutter/services.dart';

/// Name of the Android method channel for the screen, clipboard and network
/// privacy helpers (`MainActivity.kt`):
///
/// * `setSecureScreen(enabled: Boolean)` sets or clears the window's
///   `FLAG_SECURE`.
/// * `copySensitiveText(text: String)` -> `Boolean`: on Android 13+ puts
///   `text` on the clipboard marked `ClipDescription.EXTRA_IS_SENSITIVE`
///   and answers true; on older versions answers false and copies nothing.
/// * `isActiveNetworkMetered()` -> `Boolean`:
///   `ConnectivityManager.isActiveNetworkMetered()` (true when there is no
///   network or the app may not ask; see `MeteredNetwork`).
/// * `sdkInt()` -> `Int`: `Build.VERSION.SDK_INT`, the Android API level
///   (see `androidSdkInt`; the system bars depend on it).
/// * `setKeepScreenOn(on: Boolean)` sets or clears the window's
///   `FLAG_KEEP_SCREEN_ON` (see `ScreenAwake`: while Transcribe listens).
const privacyChannelName = 'io.github.aimdi.mozhi/privacy';

/// The [MethodChannel] named [privacyChannelName] on [messenger] (the
/// default binary messenger when null).
MethodChannel privacyChannel([BinaryMessenger? messenger]) =>
    MethodChannel(privacyChannelName, const StandardMethodCodec(), messenger);
