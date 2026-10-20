import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/platform/android_device.dart';

/// The style of the system bars over an app drawn in [brightness]:
/// transparent status and navigation bars (the app draws behind them, edge
/// to edge) with light icons over a dark theme (Lights out, Dim) and dark
/// icons over a light one.
///
/// The navigation bar's contrast enforcement is left to the system: with
/// three-button navigation Android keeps a translucent scrim behind the
/// buttons, so they stay legible over photos; the gesture handle needs
/// none.
SystemUiOverlayStyle systemBarsStyle(Brightness brightness) {
  final icons = brightness == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    // iOS reads the brightness of the bar's background instead.
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
  );
}

/// Keeps Android's status and navigation bars in step with the theme the
/// app shows ([Theme.of], the user's light, dark or system choice), on
/// every screen.
///
/// Place it in `MaterialApp.builder`, around the router's child. It adds an
/// [AnnotatedRegion] with [systemBarsStyle] over the whole app: Flutter
/// takes the navigation bar's style from the region at the bottom of the
/// screen and the status bar's from the region at the top, so app bars
/// still set the status bar icons themselves (their own region is found
/// first) and this one covers screens without an app bar. Without it
/// nothing styles the navigation bar: on Android 13 and 14 it stays the
/// window theme's opaque black strip with light buttons, also below a
/// light theme.
///
/// On Android it also switches the app to edge to edge once
/// ([SystemUiMode.edgeToEdge]): Android 15 and later enforce that for apps
/// targeting SDK 35+ (Mozhi targets 36), so doing the same on Android 13
/// and 14 gives every version one layout and one look. Elsewhere (the web,
/// tests on a desktop host) only the region is added.
class SystemBarsStyle extends StatefulWidget {
  const new({required this.child, this.isAndroid, super.key});

  final Widget child;

  /// Whether to switch the app to edge to edge; defaults to
  /// [runsOnAndroid].
  final bool? isAndroid;

  @override
  State<SystemBarsStyle> createState() => _SystemBarsStyleState();
}

class _SystemBarsStyleState extends State<SystemBarsStyle> {
  @override
  void initState() {
    super.initState();
    if (widget.isAndroid ?? runsOnAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsStyle(Theme.of(context).brightness),
      child: widget.child,
    );
  }
}
