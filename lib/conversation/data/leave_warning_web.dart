import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSFunction? _listener;

/// Adds (or removes) the page's `beforeunload` listener, which makes the
/// browser ask before the page is reloaded or closed (see
/// `setLeaveWarning`).
void setPlatformLeaveWarning({required bool enabled}) {
  // coverage:ignore-start
  if (enabled == (_listener != null)) return;
  if (enabled) {
    final listener = _listener = ((JSObject event) {
      event
        ..callMethod('preventDefault'.toJS)
        ..['returnValue'] = ''.toJS;
    }).toJS;
    globalContext.callMethod(
      'addEventListener'.toJS,
      'beforeunload'.toJS,
      listener,
    );
  } else {
    globalContext.callMethod(
      'removeEventListener'.toJS,
      'beforeunload'.toJS,
      _listener,
    );
    _listener = null;
  }
  // coverage:ignore-end
}
