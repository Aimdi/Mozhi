import 'dart:async';
import 'dart:developer';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/platform/app_shell_stub.dart'
    if (dart.library.js_interop) 'package:mozhi/platform/app_shell_web.dart';

/// Where the web app's offline copy of itself is ([AppShell.status]).
enum AppShellStatus {
  /// Not kept: not the web app, a browser that cannot keep it (no service
  /// workers, a page not served over https, a blocked install), a build
  /// without the shell's manifest, or "Keep the web app for offline use"
  /// is off.
  unsupported,

  /// Being saved in the browser (the first time).
  installing,

  /// Kept: the app opens in this browser with no network.
  ready,

  /// A newer version is kept too and takes over when the app reloads
  /// ([AppShell.applyUpdate]).
  updateReady,
}

/// The service workers of the app's registration, as the page sees them
/// ([AppShellBridge.workers]).
@immutable
class AppShellWorkers extends Equatable {
  const new({
    this.installing = false,
    this.waiting = false,
    this.active = false,
    this.controlled = false,
  });

  /// A worker is filling its cache (the first install, or an update).
  final bool installing;

  /// A worker has filled its cache and waits for the active one to go.
  final bool waiting;

  /// A worker serves the app (its cache is complete).
  final bool active;

  /// This page was loaded through the active worker.
  final bool controlled;

  /// The [AppShellStatus] these workers stand for: an update downloading
  /// in the background leaves the app [AppShellStatus.ready].
  AppShellStatus get status {
    if (active && waiting) return AppShellStatus.updateReady;
    if (active) return AppShellStatus.ready;
    if (installing || waiting) return AppShellStatus.installing;
    // The install failed (the worker went away).
    return AppShellStatus.unsupported;
  }

  @override
  List<Object?> get props => [installing, waiting, active, controlled];
}

/// What happens to the app's service workers ([AppShellBridge.events]).
enum AppShellEvent {
  /// A worker appeared or changed state: read [AppShellBridge.workers].
  changed,

  /// Another worker now serves the page (an update took over).
  controllerChanged,
}

/// The browser side of [AppShell]: the `mozhi_sw.js` service worker of the
/// app's base URL (`lib/platform/app_shell_web.dart`; a stand-in that is
/// never supported elsewhere, fakes in tests).
abstract interface class AppShellBridge {
  /// Whether this browser can keep the app: service workers, in a secure
  /// context (https or localhost).
  bool get isSupported;

  /// Registers `mozhi_sw.js` with the app's base URL as scope (checking
  /// for an update): its workers then, or null when the browser refused.
  Future<AppShellWorkers?> register();

  /// The workers of the registration now; null when there is none.
  Future<AppShellWorkers?> workers();

  /// Changes of the workers, once [register] ran.
  Stream<AppShellEvent> get events;

  /// Asks the waiting worker to take over; false when none waits.
  Future<bool> activateWaiting();

  /// Asks the active worker to keep the shell's files the page loaded
  /// before it was there (fonts of the scripts shown). Best effort.
  Future<void> keepLoaded();

  /// Unregisters the worker and deletes its caches.
  Future<void> unregister();

  /// Reloads the page.
  void reload();
}

/// The web app's copy of itself in the browser (the app shell service
/// worker, `web/mozhi_sw.js`): with it the app opens without a network,
/// once it has been opened.
///
/// [setEnabled] follows "Keep the web app for offline use"
/// (`AppSettings.offlineAppShell`): on registers the worker (the browser
/// then keeps the build's files, and later builds as updates), off
/// unregisters it and deletes its caches. [status] reports where the copy
/// is; [applyUpdate] reloads into a waiting update. Outside a browser (and
/// in browsers that cannot keep it) everything is
/// [AppShellStatus.unsupported] and does nothing.
class AppShell {
  new({AppShellBridge? bridge, this.reloadTimeout = const Duration(seconds: 5)})
    : _bridge = bridge ?? createAppShellBridge();

  /// The app's shell (the platform's [AppShellBridge]).
  static final AppShell instance = AppShell();

  /// How long [applyUpdate] waits for the update to take over before it
  /// reloads anyway.
  final Duration reloadTimeout;

  final AppShellBridge _bridge;
  final StreamController<AppShellStatus> _changes =
      StreamController.broadcast();
  AppShellStatus _status = AppShellStatus.unsupported;
  StreamSubscription<AppShellEvent>? _events;
  Future<void> _pending = Future.value();
  bool? _enabled;
  bool _controlled = false;
  bool _updating = false;
  bool _keptLoaded = false;
  Timer? _reloadTimer;

  /// Whether this browser can keep the app at all.
  bool get isSupported => _bridge.isSupported;

  /// The status now.
  AppShellStatus get current => _status;

  /// The status now, then each change (none is missed between the two).
  Stream<AppShellStatus> get status {
    late final StreamController<AppShellStatus> controller;
    StreamSubscription<AppShellStatus>? changes;
    controller = StreamController<AppShellStatus>(
      onListen: () {
        controller.add(_status);
        changes = _changes.stream.listen(
          controller.add,
          onDone: controller.close,
        );
      },
      onCancel: () => changes?.cancel(),
    );
    return controller.stream;
  }

  /// Keeps the app in the browser ([enabled]) or removes it (unregisters
  /// the worker, deletes its caches). Calls run one after the other; a
  /// repeated value does nothing. Never throws.
  Future<void> setEnabled({required bool enabled}) =>
      _pending = _pending.then((_) => _setEnabled(enabled));

  Future<void> _setEnabled(bool enabled) async {
    if (!_bridge.isSupported || _enabled == enabled) return;
    _enabled = enabled;
    try {
      if (enabled) {
        _events ??= _bridge.events.listen(_onEvent);
        _apply(await _bridge.register());
      } else {
        // Not awaited: nothing depends on it.
        unawaited(_events?.cancel());
        _events = null;
        _keptLoaded = false;
        _set(AppShellStatus.unsupported);
        await _bridge.unregister();
      }
    } on Object catch (error, stackTrace) {
      // A browser that refused (a private window, a blocked worker): the
      // app works online, as before.
      _set(AppShellStatus.unsupported);
      log(
        'The app shell is unavailable',
        name: 'mozhi',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Reloads into the update that waits ([AppShellStatus.updateReady]):
  /// the new worker takes over, and every page of the app reloads with it.
  /// Without an update, it just reloads.
  Future<void> applyUpdate() async {
    _updating = true;
    var activated = false;
    try {
      activated = await _bridge.activateWaiting();
    } on Object {
      // Reloads below: the browser activates it once no page uses the old.
    }
    if (!activated) {
      _bridge.reload();
      return;
    }
    // The reload comes with the new worker ([AppShellEvent.controllerChanged]).
    _reloadTimer?.cancel();
    _reloadTimer = Timer(reloadTimeout, _bridge.reload);
  }

  void _onEvent(AppShellEvent event) {
    switch (event) {
      case AppShellEvent.changed:
        unawaited(_refresh());
      case AppShellEvent.controllerChanged:
        // An update took over: this page still runs the old version, whose
        // files are gone (also when another tab applied it).
        if (_controlled || _updating) {
          _reloadTimer?.cancel();
          _bridge.reload();
        }
    }
  }

  Future<void> _refresh() async {
    try {
      final workers = await _bridge.workers();
      if (_enabled != true) return;
      _apply(workers);
    } on Object {
      // The next change reads them again.
    }
  }

  void _apply(AppShellWorkers? workers) {
    if (_enabled != true) return;
    if (workers == null) {
      _set(AppShellStatus.unsupported);
      return;
    }
    _controlled = _controlled || workers.controlled;
    final status = workers.status;
    if (status != AppShellStatus.unsupported &&
        !_keptLoaded &&
        workers.active) {
      _keptLoaded = true;
      unawaited(_bridge.keepLoaded().catchError((Object _) {}));
    }
    _set(status);
  }

  void _set(AppShellStatus status) {
    if (status == _status) return;
    _status = status;
    _changes.add(status);
  }

  /// Stops listening (tests).
  @visibleForTesting
  Future<void> dispose() async {
    _reloadTimer?.cancel();
    await _events?.cancel();
    // Not awaited: a listener that never cancels would keep it open.
    unawaited(_changes.close());
  }
}
