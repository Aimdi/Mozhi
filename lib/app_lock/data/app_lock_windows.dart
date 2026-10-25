import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';

/// The start route of the translucent screen-translate window
/// (`ScreenTranslateHost.location`, `ScreenTranslateActivity.kt`).
const screenTranslateLocation = '/screen-translate';

/// Which window of the app this engine runs in, for the app lock.
enum AppLockWindow {
  /// The main window (in Recents): the full lock screen.
  main,

  /// The translucent quick translate window (text selected in another
  /// app): a compact lock card above the other app.
  quickTranslate,

  /// The translucent screen-translate window: it waits for the lock
  /// itself after taking its screenshot, so nothing is drawn over the
  /// screen it captures.
  screenTranslate;

  /// The window of this engine, from the route it was started at
  /// ([initialRoute], default the platform's) and [quickHost] (default
  /// [QuickTranslateHost.instance]). Always [main] in a browser.
  static AppLockWindow current({
    String Function()? initialRoute,
    QuickTranslateHost? quickHost,
  }) {
    if (kIsWeb) return main;
    if ((quickHost ?? QuickTranslateHost.instance).isActive) {
      return quickTranslate;
    }
    final route = (initialRoute ?? _platformRoute)();
    return Uri.tryParse(route)?.path == screenTranslateLocation
        ? screenTranslate
        : main;
  }

  static String _platformRoute() =>
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;

  /// Whether the lock keeps this window out of Recents' previews: only the
  /// main window shows there (the others are excluded from Recents, and
  /// `FLAG_SECURE` would black out the screen-translate capture).
  bool get protectsWindow => this == main;
}
