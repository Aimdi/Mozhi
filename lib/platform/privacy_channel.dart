import 'package:flutter/services.dart';

/// Name of the Android method channel for the screen and clipboard privacy
/// helpers (`MainActivity.kt`):
///
/// * `setSecureScreen(enabled: Boolean)` sets or clears the window's
///   `FLAG_SECURE`.
/// * `copySensitiveText(text: String)` -> `Boolean`: on Android 13+ puts
///   `text` on the clipboard marked `ClipDescription.EXTRA_IS_SENSITIVE`
///   and answers true; on older versions answers false and copies nothing.
const privacyChannelName = 'io.github.aimdi.mozhi/privacy';

/// The [MethodChannel] named [privacyChannelName] on [messenger] (the
/// default binary messenger when null).
MethodChannel privacyChannel([BinaryMessenger? messenger]) =>
    MethodChannel(privacyChannelName, const StandardMethodCodec(), messenger);
