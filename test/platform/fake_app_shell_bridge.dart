import 'dart:async';

import 'package:mozhi/platform/app_shell.dart';

/// An [AppShellBridge] whose registration has the workers the test sets
/// ([next], [change]) and that counts what the shell asked for.
class FakeAppShellBridge implements AppShellBridge {
  /// What [register] and [workers] answer.
  AppShellWorkers? next;

  bool hasWaiting = true;
  bool failRegister = false;
  bool failWorkers = false;
  bool failActivation = false;

  int registered = 0;
  int unregistered = 0;
  int activations = 0;
  int keptLoaded = 0;
  int reloads = 0;

  final StreamController<AppShellEvent> _events = StreamController.broadcast();

  /// The workers change to [workers] ([AppShellEvent.changed]).
  void change(AppShellWorkers workers) {
    next = workers;
    emit(AppShellEvent.changed);
  }

  void emit(AppShellEvent event) => _events.add(event);

  @override
  bool get isSupported => true;

  @override
  Stream<AppShellEvent> get events => _events.stream;

  @override
  Future<AppShellWorkers?> register() async {
    registered++;
    if (failRegister) throw StateError('SecurityError');
    return next;
  }

  @override
  Future<AppShellWorkers?> workers() async {
    if (failWorkers) throw StateError('gone');
    return next;
  }

  @override
  Future<bool> activateWaiting() async {
    activations++;
    if (failActivation) throw StateError('InvalidStateError');
    return hasWaiting;
  }

  @override
  Future<void> keepLoaded() async => keptLoaded++;

  @override
  Future<void> unregister() async => unregistered++;

  @override
  void reload() => reloads++;
}
