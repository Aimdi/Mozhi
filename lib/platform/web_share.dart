import 'package:flutter/foundation.dart';
import 'package:mozhi/platform/web_share_stub.dart'
    if (dart.library.js_interop) 'package:mozhi/platform/web_share_web.dart'
    as platform;

/// Tests set this to pretend [canShareText] is true or false; null asks
/// the platform.
@visibleForTesting
bool? debugCanShareText;

/// Whether the system share sheet can share text: always in the app; in a
/// browser only with the Web Share API (`navigator.share`). Without it
/// `share_plus` would open a blank `mailto:` window instead, so the app
/// offers no Share button there (Copy remains).
bool get canShareText => debugCanShareText ?? platform.platformCanShareText();
