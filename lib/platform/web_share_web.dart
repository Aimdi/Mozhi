import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('navigator')
external JSObject? get _navigator;

/// Whether the browser has the Web Share API (`'share' in navigator`).
/// Never throws.
// coverage:ignore-start
bool platformCanShareText() {
  try {
    final navigator = _navigator;
    return navigator != null && navigator.has('share');
  } on Object {
    return false;
  }
}

// coverage:ignore-end
