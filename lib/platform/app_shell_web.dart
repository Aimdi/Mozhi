// coverage:ignore-file
// Browser-only (dart:js_interop): exercised by the web build and its
// end-to-end test (e2e/tests/offline_shell.spec.js), not by the VM tests
// (AppShell's logic is tested with a fake bridge).

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:mozhi/platform/app_shell.dart';

/// The browser's [AppShellBridge]: `navigator.serviceWorker`.
AppShellBridge createAppShellBridge() => BrowserAppShellBridge();

/// `web/mozhi_sw.js` registered for the app's base URL (`document.baseURI`,
/// which follows `<base href>`), its registration's workers and the
/// messages the worker understands (`mozhi-shell-activate`,
/// `mozhi-shell-keep`). Its caches are named `mozhi-shell:<scope path>:`
/// followed by the build's version, like the worker names them.
class BrowserAppShellBridge implements AppShellBridge {
  static const _script = 'mozhi_sw.js';

  final StreamController<AppShellEvent> _events = StreamController.broadcast();
  JSObject? _registration;
  final List<JSObject> _watched = [];
  bool _listening = false;

  late final JSFunction _onChange = ((JSAny? _) {
    _watchWorkers();
    _events.add(AppShellEvent.changed);
  }).toJS;

  late final JSFunction _onControllerChange = ((JSAny? _) {
    _events.add(AppShellEvent.controllerChanged);
  }).toJS;

  static JSObject? get _container {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    if (navigator == null || !navigator.has('serviceWorker')) return null;
    return navigator.getProperty<JSObject?>('serviceWorker'.toJS);
  }

  /// The app's base URL (its folder, without query or fragment): the
  /// worker's scope.
  static Uri get _scope {
    final document = globalContext.getProperty<JSObject>('document'.toJS);
    final base = document.getProperty<JSString>('baseURI'.toJS).toDart;
    return Uri.parse(base).resolve('./');
  }

  static String get _scopeUrl => _scope.toString();

  @override
  bool get isSupported {
    try {
      final secure = globalContext.getProperty<JSAny?>('isSecureContext'.toJS);
      return _container != null &&
          secure.isA<JSBoolean>() &&
          (secure! as JSBoolean).toDart;
    } on Object {
      return false;
    }
  }

  @override
  Stream<AppShellEvent> get events => _events.stream;

  @override
  Future<AppShellWorkers?> register() async {
    final container = _container;
    if (container == null) return null;
    final scope = _scopeUrl;
    final options = JSObject()
      ..setProperty('scope'.toJS, scope.toJS)
      // The worker itself is always checked with the server (no HTTP
      // cache), so a new build is found on the next start.
      ..setProperty('updateViaCache'.toJS, 'none'.toJS);
    final result = await container
        .callMethod<JSPromise<JSAny?>>(
          'register'.toJS,
          Uri.parse(scope).resolve(_script).toString().toJS,
          options,
        )
        .toDart;
    // Browsers (and test drivers) that block service workers may resolve
    // without a registration.
    if (result == null || !result.isA<JSObject>()) return null;
    final registration = result as JSObject;
    if (!registration.has('scope')) return null;
    _registration = registration;
    if (!_listening) {
      _listening = true;
      registration.callMethod<JSAny?>(
        'addEventListener'.toJS,
        'updatefound'.toJS,
        _onChange,
      );
      container.callMethod<JSAny?>(
        'addEventListener'.toJS,
        'controllerchange'.toJS,
        _onControllerChange,
      );
    }
    _watchWorkers();
    return _snapshot(registration, container);
  }

  @override
  Future<AppShellWorkers?> workers() async {
    final container = _container;
    final registration = _registration;
    if (container == null || registration == null) return null;
    return _snapshot(registration, container);
  }

  @override
  Future<bool> activateWaiting() async {
    final registration = _registration;
    if (registration == null) return false;
    // The installed worker: `waiting`, or still `installing` when the
    // registration's attributes lag behind its state.
    final waiting = _workersOf(registration)
        .where((worker) => _stateOf(worker) == 'installed')
        .firstOrNull;
    if (waiting == null) return false;
    waiting.callMethod<JSAny?>(
      'postMessage'.toJS,
      {'type': 'mozhi-shell-activate'}.jsify(),
    );
    return true;
  }

  @override
  Future<void> keepLoaded() async {
    final active = _registration?.getProperty<JSObject?>('active'.toJS);
    if (active == null) return;
    final performance = globalContext.getProperty<JSObject?>(
      'performance'.toJS,
    );
    if (performance == null || !performance.has('getEntriesByType')) return;
    final entries = performance.callMethod<JSArray<JSObject>>(
      'getEntriesByType'.toJS,
      'resource'.toJS,
    );
    final scope = _scopeUrl;
    final urls = <String>[
      for (final entry in entries.toDart)
        if (entry.getProperty<JSAny?>('name'.toJS) case final JSString name
            when name.toDart.startsWith(scope))
          name.toDart,
    ];
    if (urls.isEmpty) return;
    active.callMethod<JSAny?>(
      'postMessage'.toJS,
      {'type': 'mozhi-shell-keep', 'urls': urls}.jsify(),
    );
  }

  @override
  Future<void> unregister() async {
    _registration = null;
    final scope = _scopeUrl;
    final container = _container;
    if (container != null && container.has('getRegistrations')) {
      final registrations = await container
          .callMethod<JSPromise<JSArray<JSObject>>>('getRegistrations'.toJS)
          .toDart;
      for (final registration in registrations.toDart) {
        final value = registration.getProperty<JSAny?>('scope'.toJS);
        if (value.isA<JSString>() && (value! as JSString).toDart == scope) {
          await registration
              .callMethod<JSPromise<JSAny?>>('unregister'.toJS)
              .toDart;
        }
      }
    }
    final caches = globalContext.getProperty<JSObject?>('caches'.toJS);
    if (caches == null) return;
    final prefix = 'mozhi-shell:${_scope.path}:';
    final names = await caches
        .callMethod<JSPromise<JSArray<JSString>>>('keys'.toJS)
        .toDart;
    for (final name in names.toDart) {
      if (!name.toDart.startsWith(prefix)) continue;
      await caches.callMethod<JSPromise<JSAny?>>('delete'.toJS, name).toDart;
    }
  }

  @override
  void reload() {
    globalContext
        .getProperty<JSObject>('location'.toJS)
        .callMethod<JSAny?>('reload'.toJS);
  }

  /// Listens to the state changes of the registration's workers.
  void _watchWorkers() {
    final registration = _registration;
    if (registration == null) return;
    for (final name in ['installing', 'waiting', 'active']) {
      final worker = registration.getProperty<JSObject?>(name.toJS);
      if (worker == null ||
          _watched.any((known) => known.strictEquals(worker).toDart)) {
        continue;
      }
      _watched.add(worker);
      worker.callMethod<JSAny?>(
        'addEventListener'.toJS,
        'statechange'.toJS,
        _onChange,
      );
    }
  }

  /// The workers of [registration] (installing, waiting, active), each
  /// once.
  static List<JSObject> _workersOf(JSObject registration) {
    final workers = <JSObject>[];
    for (final name in ['installing', 'waiting', 'active']) {
      final worker = registration.getProperty<JSObject?>(name.toJS);
      if (worker != null &&
          !workers.any((known) => known.strictEquals(worker).toDart)) {
        workers.add(worker);
      }
    }
    return workers;
  }

  static String _stateOf(JSObject worker) {
    final state = worker.getProperty<JSAny?>('state'.toJS);
    return state.isA<JSString>() ? (state! as JSString).toDart : '';
  }

  /// The workers by their own states, not by the registration's
  /// attributes: Chrome fires a worker's `statechange` (to `installed`)
  /// before it moves the worker from `installing` to `waiting`, and no
  /// event follows that move.
  static AppShellWorkers _snapshot(JSObject registration, JSObject container) {
    final states = [
      for (final worker in _workersOf(registration)) _stateOf(worker),
    ];
    final controller = container.getProperty<JSObject?>('controller'.toJS);
    final script = controller?.getProperty<JSAny?>('scriptURL'.toJS);
    return AppShellWorkers(
      installing: states.contains('installing') || states.contains('parsed'),
      waiting: states.contains('installed'),
      active: states.contains('activating') || states.contains('activated'),
      controlled:
          script.isA<JSString>() &&
          (script! as JSString).toDart.endsWith('/$_script'),
    );
  }
}
