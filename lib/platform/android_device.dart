import 'package:mozhi/platform/android_device_stub.dart'
    if (dart.library.io) 'package:mozhi/platform/android_device_io.dart'
    as impl;

/// Whether the app really runs on Android (the host operating system).
///
/// Unlike `defaultTargetPlatform`, which widget tests set to Android, this
/// is false in tests on a desktop host, so the Android-only platform
/// channels (`SecureScreen`, `ClipboardService`) are not called there
/// unless a test asks for them.
bool get runsOnAndroid => impl.runsOnAndroid;
