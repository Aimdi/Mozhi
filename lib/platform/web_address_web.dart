import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Replaces the page's address with [address] (same origin), keeping the
/// history entry and its state (Flutter's router keeps its own there).
/// Never throws.
// coverage:ignore-start
void replaceWebAddress(String address) {
  try {
    final history = globalContext.getProperty<JSObject?>('history'.toJS);
    if (history == null) return;
    history.callMethod<JSAny?>(
      'replaceState'.toJS,
      history.getProperty<JSAny?>('state'.toJS),
      ''.toJS,
      address.toJS,
    );
  } on Object {
    // The address stays as it was.
  }
}

// coverage:ignore-end
