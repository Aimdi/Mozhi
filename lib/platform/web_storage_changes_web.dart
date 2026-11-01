import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// The keys of the browser's storage that another tab of this origin
/// changed (the window's `storage` events; null when it cleared all of
/// it), while listened to. A tab never hears its own changes.
// coverage:ignore-start
Stream<String?> webStorageChanges() {
  late final StreamController<String?> controller;
  JSFunction? listener;
  controller = StreamController<String?>.broadcast(
    onListen: () {
      listener = ((JSObject event) {
        final key = event['key'];
        controller.add(key.isA<JSString>() ? (key! as JSString).toDart : null);
      }).toJS;
      globalContext.callMethod<JSAny?>(
        'addEventListener'.toJS,
        'storage'.toJS,
        listener,
      );
    },
    onCancel: () {
      globalContext.callMethod<JSAny?>(
        'removeEventListener'.toJS,
        'storage'.toJS,
        listener,
      );
      listener = null;
    },
  );
  return controller.stream;
}

// coverage:ignore-end
