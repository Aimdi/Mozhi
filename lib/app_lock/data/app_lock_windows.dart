import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';

/// The start route of the translucent screen-translate window
/// (`ScreenTranslateHost.location`, `ScreenTranslateActivity.kt`).
const screenTranslateLocation = '/screen-translate';

/// Which window of the app this engine runs in, for the app lock.
///
/// A window is known by two things that must agree ([current]): the route
/// its engine was started at, and the window its Android activity says it
/// is ([declared], a Dart entrypoint argument set by the activity's class).
/// Neither is trusted alone: any app can start the main activity at any
/// route (Flutter reads the route from the intent), and only the main
/// window is ever the safe answer.
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

  /// The Dart entrypoint argument that names the window:
  /// `window=<name>` (`MainActivity.WINDOW_ARGUMENT`), with the [name] of
  /// a value.
  static const entrypointArgumentPrefix = 'window=';

  /// The window the platform side started this engine as, from `main`'s
  /// entrypoint arguments ([declare]); null when it named none (tests, the
  /// web).
  static AppLockWindow? declared;

  /// Sets [declared] from `main`'s [args] ([fromEntrypointArgs]).
  static void declare(List<String> args) => declared = fromEntrypointArgs(args);

  /// The window named by the first `window=<name>` of [args]; null without
  /// one or for an unknown name.
  static AppLockWindow? fromEntrypointArgs(List<String> args) {
    for (final argument in args) {
      if (argument.startsWith(entrypointArgumentPrefix)) {
        final name = argument.substring(entrypointArgumentPrefix.length);
        return values.asNameMap()[name];
      }
    }
    return null;
  }

  /// The window of this engine: the one the route it was started at
  /// ([initialRoute], default the platform's) and [quickHost] (default
  /// [QuickTranslateHost.instance]) point to, when the platform side
  /// declared the same ([platformWindow], default [declared]); [main]
  /// otherwise. Always [main] in a browser.
  static AppLockWindow current({
    String Function()? initialRoute,
    QuickTranslateHost? quickHost,
    AppLockWindow? platformWindow,
  }) {
    if (kIsWeb) return main;
    final AppLockWindow byRoute;
    if ((quickHost ?? QuickTranslateHost.instance).isActive) {
      byRoute = quickTranslate;
    } else {
      final route = (initialRoute ?? _platformRoute)();
      byRoute = Uri.tryParse(route)?.path == screenTranslateLocation
          ? screenTranslate
          : main;
    }
    return byRoute == (platformWindow ?? declared) ? byRoute : main;
  }

  static String _platformRoute() =>
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;

  /// Whether the lock keeps this window out of Recents' previews: only the
  /// main window shows there (the others are excluded from Recents, and
  /// `FLAG_SECURE` would black out the screen-translate capture).
  bool get protectsWindow => this == main;
}
