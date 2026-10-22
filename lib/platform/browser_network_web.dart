import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('navigator')
external JSObject? get _navigator;

/// Whether the browser reports mobile data or the user's data saver
/// (`navigator.connection`: `type == 'cellular'` or `saveData`). Most
/// browsers (Firefox, Safari, desktop Chrome on Wi-Fi or a cable) cannot
/// tell, and count as not metered: the web app cannot know, unlike the
/// Android app (which then asks). Never throws.
// coverage:ignore-start
Future<bool> browserConnectionIsMetered() async {
  try {
    final connection = _navigator?['connection'];
    if (connection == null || !connection.isA<JSObject>()) return false;
    final info = connection as JSObject;
    final type = info['type'];
    final saveData = info['saveData'];
    return (type.isA<JSString>() && (type! as JSString).toDart == 'cellular') ||
        (saveData.isA<JSBoolean>() && (saveData! as JSBoolean).toDart);
  } on Object {
    return false;
  }
}

// coverage:ignore-end
