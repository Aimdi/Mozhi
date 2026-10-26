import 'package:mozhi/platform/app_shell.dart';

/// Outside a browser there is no web app to keep: never supported.
AppShellBridge createAppShellBridge() => const UnsupportedAppShellBridge();

/// An [AppShellBridge] that is never supported and does nothing (the
/// Android app, VM tests).
class UnsupportedAppShellBridge implements AppShellBridge {
  const new();

  @override
  bool get isSupported => false;

  @override
  Future<AppShellWorkers?> register() async => null;

  @override
  Future<AppShellWorkers?> workers() async => null;

  @override
  Stream<AppShellEvent> get events => const Stream.empty();

  @override
  Future<bool> activateWaiting() async => false;

  @override
  Future<void> keepLoaded() async {}

  @override
  Future<void> unregister() async {}

  @override
  void reload() {}
}
