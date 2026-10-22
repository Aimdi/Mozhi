import 'dart:js_interop';

@JS('navigator.wakeLock')
external _WakeLock? get _wakeLock;

extension type _WakeLock._(JSObject _) implements JSObject {
  external JSPromise<_Sentinel> request(JSString type);
}

extension type _Sentinel._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> release();
}

/// The lock held now; null again once released.
// ignore: use_late_for_private_fields_and_variables
_Sentinel? _held;

/// The browser's screen wake lock (`navigator.wakeLock.request('screen')`)
/// where it exists; the browser drops it when the page is hidden.
class WebWakeLock {
  const new();

  // coverage:ignore-start
  Future<void> acquire() async {
    final lock = _wakeLock;
    if (lock == null || _held != null) return;
    _held = await lock.request('screen'.toJS).toDart;
  }

  Future<void> release() async {
    final held = _held;
    _held = null;
    await held?.release().toDart;
  }

  // coverage:ignore-end
}
