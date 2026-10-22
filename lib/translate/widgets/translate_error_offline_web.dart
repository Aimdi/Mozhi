import 'dart:js_interop';

@JS('navigator.onLine')
external bool get _browserOnline;

/// Whether the browser says it has no network connection
/// (`navigator.onLine` is false). Nothing is sent. False when it can't
/// tell.
Future<bool> deviceSeemsOffline() async {
  try {
    return !_browserOnline;
  } on Object {
    return false;
  }
}
