import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// What the browser's storage quota leaves this origin
/// (`navigator.storage.estimate()`: `quota - usage`), in bytes; null when
/// the browser cannot tell (no Storage API, an error). Never throws.
// coverage:ignore-start
Future<int?> browserStorageLeft() async {
  try {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    final storage = navigator?.getProperty<JSObject?>('storage'.toJS);
    if (storage == null || !storage.has('estimate')) return null;
    final promise = storage.callMethod<JSPromise<JSObject?>>('estimate'.toJS);
    final estimate = await promise.toDart;
    if (estimate == null) return null;
    final quota = estimate.getProperty<JSAny?>('quota'.toJS);
    final usage = estimate.getProperty<JSAny?>('usage'.toJS);
    if (!quota.isA<JSNumber>() || !usage.isA<JSNumber>()) return null;
    final left =
        (quota! as JSNumber).toDartDouble - (usage! as JSNumber).toDartDouble;
    return left < 0 ? 0 : left.floor();
  } on Object {
    return null;
  }
}

// coverage:ignore-end
