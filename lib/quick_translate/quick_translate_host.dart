import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The translucent Android window that shows only the quick translate
/// sheet above the app the text was selected in (`QuickTranslateActivity`,
/// started for "Translate with Mozhi" and "Translate offline" in the text
/// selection toolbar).
///
/// The window runs its own copy of the app, started at [location]: the
/// router shows a transparent page there ([QuickTranslateHostView]), the
/// selection arrives as usual (`SharedTextHandler`) and opens the sheet,
/// and closing the sheet closes the window ([close]). "Open in app" and the
/// offline languages continue in the main window ([openTextInApp],
/// [openLocationInApp]), which also closes this one. Replace answers the
/// calling app through `SharedTextService.returnResult` as before.
///
/// Platform side (`QuickTranslateActivity.kt`), MethodChannel [channelName]:
/// `close()`, `openInApp({text})` (the main window's translate tab, like
/// shared text) and `openInApp({location})` (a `mozhi://` link to that
/// location). Everything is a no-op unless [isActive].
class QuickTranslateHost {
  /// [initialRoute] reads the route the engine was started at (default:
  /// the platform's, `PlatformDispatcher.defaultRouteName`).
  new({MethodChannel? channel, String Function()? initialRoute})
    : _channel = channel ?? const MethodChannel(channelName),
      _initialRoute = initialRoute ?? _platformRoute;

  /// The start route of the quick translate window.
  static const location = '/quick-translate';

  static const channelName = 'io.github.aimdi.mozhi/quick_translate';

  /// The host of this engine.
  static QuickTranslateHost instance = QuickTranslateHost();

  final MethodChannel _channel;
  final String Function() _initialRoute;

  static String _platformRoute() =>
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;

  /// Whether this engine runs in the quick translate window (it was
  /// started at [location]). Never in a browser.
  bool get isActive {
    if (kIsWeb) return false;
    return Uri.tryParse(_initialRoute())?.path == location;
  }

  /// Closes the window.
  Future<void> close() => _invoke('close');

  /// Opens [text] in the main window's translate tab (as shared text: an
  /// AI model never translates it on its own) and closes this window.
  Future<void> openTextInApp(String text) =>
      _invoke('openInApp', {'text': text});

  /// Opens the main window at [location] (e.g. the offline languages) and
  /// closes this window.
  Future<void> openLocationInApp(String location) =>
      _invoke('openInApp', {'location': location});

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!isActive) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not in the quick translate window after all.
    } on PlatformException {
      // The window is closing.
    }
  }
}

/// The page of [QuickTranslateHost.location]: nothing but a transparent
/// surface (the app the text was selected in shows through) below the
/// quick translate sheet.
class QuickTranslateHostView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.quickTranslateTitle,
      child: const SizedBox.expand(),
    );
  }
}
