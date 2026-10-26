import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// How the screenshot of the screen-translate window came out
/// ([ScreenTranslateHost.capture]).
@immutable
sealed class ScreenCapture {
  const new();
}

/// One frame of the screen, as an encoded PNG.
///
/// Equality is identity on purpose: comparing megabytes of pixels on every
/// state change would be wasteful (like `PickedImage`).
final class ScreenCaptured extends ScreenCapture {
  const new({
    required this.bytes,
    required this.width,
    required this.height,
    this.blank = false,
  });

  /// The PNG (the platform side has already deleted its file).
  final Uint8List bytes;
  final int width;
  final int height;

  /// The frame came out black: the app on the screen blocks screenshots
  /// (`FLAG_SECURE`), so there is nothing to read.
  final bool blank;

  @override
  String toString() =>
      'ScreenCaptured(${width}x$height, ${bytes.lengthInBytes} bytes'
      '${blank ? ', blank' : ''})';
}

/// The user turned the system's screen-capture dialog down.
final class ScreenCaptureDeclined extends ScreenCapture {
  const new();
}

/// Nothing could be captured; [reason] is the platform's code (for
/// support; the user sees one message for all of them).
final class ScreenCaptureFailed extends ScreenCapture {
  const new(this.reason);

  final String reason;

  @override
  bool operator ==(Object other) =>
      other is ScreenCaptureFailed && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'ScreenCaptureFailed($reason)';
}

/// The translucent Android window that translates what is on the screen
/// (`ScreenTranslateActivity`, started by the Quick Settings tile, the
/// launcher shortcut and the bubble).
///
/// The window runs its own copy of the app, started at [location]: the
/// router shows only the screen-translate page there
/// ([screenTranslateWindowRedirect]). As soon as it opens, the platform side
/// asks for the system's screen-capture consent (every time) and takes
/// one frame while this window still draws nothing; [capture] answers once
/// that is done.
///
/// Platform side (`ScreenTranslateActivity.kt`), MethodChannel
/// [channelName]: `screenshot()`, `close()`, `openInApp({text})` (the main
/// window's translate tab, like shared text) and `openInApp({location})` (a
/// `mozhi://` link to that location), the last two closing this window.
/// Everything is a no-op unless [isActive].
class ScreenTranslateHost {
  /// [initialRoute] reads the route the engine was started at (default:
  /// the platform's, `PlatformDispatcher.defaultRouteName`).
  new({MethodChannel? channel, String Function()? initialRoute})
    : _channel = channel ?? const MethodChannel(channelName),
      _initialRoute = initialRoute ?? _platformRoute;

  /// The start route of the screen-translate window.
  static const location = '/screen-translate';

  static const channelName = 'io.github.aimdi.mozhi/screen_translate';

  /// The host of this engine.
  static ScreenTranslateHost instance = ScreenTranslateHost();

  final MethodChannel _channel;
  final String Function() _initialRoute;
  Future<ScreenCapture>? _capture;
  bool _leaving = false;

  static String _platformRoute() =>
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;

  /// Whether this engine runs in the screen-translate window (it was
  /// started at [location]). Never in a browser.
  bool get isActive {
    if (kIsWeb) return false;
    return Uri.tryParse(_initialRoute())?.path == location;
  }

  /// The window's screenshot, once the user agreed and it was taken (or
  /// why there is none). Asked once: later calls get the same answer, and
  /// the platform has deleted the file by then.
  Future<ScreenCapture> capture() => _capture ??= _takeScreenshot();

  Future<ScreenCapture> _takeScreenshot() async {
    if (!isActive) return const ScreenCaptureFailed('inactive');
    final Map<String, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<String, Object?>('screenshot');
    } on MissingPluginException {
      return const ScreenCaptureFailed('unavailable');
    } on PlatformException catch (error) {
      return ScreenCaptureFailed(error.code);
    }
    return parseScreenCapture(answer);
  }

  /// Closes the window: the app below is back.
  Future<void> close() => _invoke('close');

  /// Opens [text] in the main window's translate tab (as shared text: an
  /// AI model never translates it on its own) and closes this window.
  Future<void> openTextInApp(String text) {
    if (text.trim().isEmpty) return Future.value();
    return _leave({'text': text});
  }

  /// Opens the main window at [location] (e.g. the offline languages) and
  /// closes this window.
  Future<void> openLocationInApp(String location) =>
      _leave({'location': location});

  /// Leaves for the main window once (the window is closing then).
  Future<void> _leave(Map<String, String> arguments) async {
    if (_leaving) return;
    _leaving = true;
    await _invoke('openInApp', arguments);
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!isActive) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Not in the screen-translate window after all.
    } on PlatformException {
      // The window is closing.
    }
  }
}

/// The [ScreenCapture] of the platform's `screenshot()` [answer]:
/// `{status: "ok", bytes, width, height, blank}`, `{status: "declined"}`
/// or `{status: "failed", reason}`. Anything else is a failure.
ScreenCapture parseScreenCapture(Map<String, Object?>? answer) {
  if (answer == null) return const ScreenCaptureFailed('none');
  switch (answer['status']) {
    case 'declined':
      return const ScreenCaptureDeclined();
    case 'ok':
      final bytes = answer['bytes'];
      final width = answer['width'];
      final height = answer['height'];
      if (bytes is! Uint8List ||
          bytes.isEmpty ||
          width is! int ||
          height is! int ||
          width <= 0 ||
          height <= 0) {
        return const ScreenCaptureFailed('invalid');
      }
      return ScreenCaptured(
        bytes: bytes,
        width: width,
        height: height,
        blank: answer['blank'] == true,
      );
    case 'failed':
      final reason = answer['reason'];
      return ScreenCaptureFailed(reason is String ? reason : 'unknown');
    default:
      return const ScreenCaptureFailed('invalid');
  }
}

/// The router's redirect in the screen-translate window: the window shows
/// nothing but [ScreenTranslateHost.location]. Any other app location (a
/// fix such as the offline languages, the settings) opens in the main
/// window instead ([ScreenTranslateHost.openLocationInApp], which closes
/// this one); null keeps the window's own location.
String? screenTranslateWindowRedirect(Uri uri, ScreenTranslateHost host) {
  if (uri.path == ScreenTranslateHost.location) return null;
  final path = uri.path;
  if (!uri.hasScheme &&
      !uri.hasAuthority &&
      path.startsWith('/') &&
      path != '/' &&
      !path.startsWith('//')) {
    unawaited(host.openLocationInApp(uri.toString()));
  }
  return ScreenTranslateHost.location;
}
