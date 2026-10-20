import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device_stub.dart'
    if (dart.library.io) 'package:mozhi/platform/android_device_io.dart'
    as impl;
import 'package:mozhi/platform/privacy_channel.dart';

/// Whether the app really runs on Android (the host operating system).
///
/// Unlike `defaultTargetPlatform`, which widget tests set to Android, this
/// is false in tests on a desktop host, so the Android-only platform
/// channels (`SecureScreen`, `ClipboardService`) are not called there
/// unless a test asks for them.
bool get runsOnAndroid => impl.runsOnAndroid;

/// The Android API level the app runs on (`Build.VERSION.SDK_INT`, e.g. 28
/// for Android 9), asked from `MainActivity.kt` over the [privacyChannel]
/// ([channel] in tests).
///
/// Null without asking when not on Android ([isAndroid], default
/// [runsOnAndroid]), and when the platform side cannot tell. Never throws.
Future<int?> androidSdkInt({MethodChannel? channel, bool? isAndroid}) async {
  if (!(isAndroid ?? runsOnAndroid)) return null;
  try {
    return await (channel ?? privacyChannel()).invokeMethod<int>('sdkInt');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
