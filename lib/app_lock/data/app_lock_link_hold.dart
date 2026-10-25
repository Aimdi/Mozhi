import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';

/// Holds the locations the platform asks the app to open while [lock] is
/// locked (`mozhi://` links, files shared to the image screen or the
/// document translator, the home-screen widget's Type and Camera buttons)
/// and opens the last one once it is unlocked, with [open].
///
/// While locked the app's screens stay alive but hidden (`AppLockGate`):
/// without this, a link would open its screen behind the lock and start
/// what it asks for (fill in the translator, open the camera, load a
/// file). It is a [WidgetsBindingObserver] that answers
/// [didPushRouteInformation] before the router's route information
/// provider does, so it must be [attach]ed before the router is created.
class AppLockLinkHold with WidgetsBindingObserver {
  new({required this.lock, required this.open});

  final AppLock lock;

  /// Opens a held location once unlocked (the app hands it to the router's
  /// route information provider, as if the platform pushed it then).
  final void Function(RouteInformation location) open;

  RouteInformation? _held;
  StreamSubscription<bool>? _changes;

  /// The location waiting for the unlock (the last one asked for).
  @visibleForTesting
  RouteInformation? get held => _held;

  /// Starts holding; call it before the router listens to the platform.
  void attach() {
    WidgetsBinding.instance.addObserver(this);
    _changes = lock.changes.listen((locked) {
      if (!locked) _release();
    });
  }

  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    if (!lock.isLocked) return false;
    _held = routeInformation;
    return true;
  }

  void _release() {
    final held = _held;
    _held = null;
    if (held != null) open(held);
  }

  /// Stops holding (a held location is dropped).
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    _held = null;
    await _changes?.cancel();
  }
}
