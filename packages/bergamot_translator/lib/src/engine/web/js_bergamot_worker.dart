// The browser side of the web engine (dart:js_interop only; compiled for
// the web alone, see engine_factory.dart).
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory(JSString url);

  external void postMessage(JSAny? message);
  external JSFunction? get onmessage;
  external set onmessage(JSFunction? handler);
  external JSFunction? get onerror;
  external set onerror(JSFunction? handler);
  external void terminate();
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

/// [BergamotWorkerChannel] over a dedicated `Worker` running
/// `web/bergamot/worker.js` (at [url], relative to the page's base URL).
/// The worker starts with the first request and again after [terminate]
/// or when it could not be started.
final class JsBergamotWorkerChannel implements BergamotWorkerChannel {
  new([this.url = defaultBergamotWorkerUrl]);

  final String url;

  _Worker? _worker;
  var _nextId = 1;
  final Map<int, Completer<Object?>> _pending = {};

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]) {
    final _Worker worker;
    try {
      worker = _worker ??= _start();
    } on Object catch (error) {
      return Future.error(
        BergamotWorkerException(
          BergamotWorkerErrorKind.unsupported,
          'Cannot start $url: $error',
        ),
      );
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    final message = JSObject()
      ..['id'] = id.toJS
      ..['op'] = op.toJS;
    for (final MapEntry(:key, :value) in arguments.entries) {
      message[key] = _toJs(value);
    }
    try {
      worker.postMessage(message);
    } on Object catch (error) {
      _pending.remove(id);
      return Future.error(
        BergamotWorkerException(
          BergamotWorkerErrorKind.protocol,
          'Cannot send $op: $error',
        ),
      );
    }
    return completer.future;
  }

  @override
  void terminate() {
    _worker?.terminate();
    _worker = null;
    _failAll('The worker was stopped');
  }

  _Worker _start() {
    return _Worker(url.toJS)
      ..onmessage = ((_MessageEvent event) => _receive(event.data)).toJS
      ..onerror = ((JSObject event) {
        // The script failed to load or threw at the top level: every
        // pending request fails, the next one starts a new worker.
        final message = event['message'];
        _worker?.terminate();
        _worker = null;
        _failAll(
          message.isA<JSString>()
              ? (message! as JSString).toDart
              : 'The worker failed to start',
          kind: BergamotWorkerErrorKind.unsupported,
        );
      }).toJS;
  }

  void _receive(JSAny? data) {
    final message = data.dartify();
    if (message is! Map) return;
    final id = message['id'];
    final completer = id is num ? _pending.remove(id.toInt()) : null;
    if (completer == null) return;
    if (message['ok'] == true) {
      completer.complete(message['result']);
    } else {
      final error = message['error'];
      completer.completeError(
        BergamotWorkerException(
          BergamotWorkerErrorKind.of(error is Map ? error['kind'] : null),
          error is Map ? '${error['message']}' : 'Unknown worker error',
        ),
      );
    }
  }

  void _failAll(
    String message, {
    BergamotWorkerErrorKind kind = BergamotWorkerErrorKind.protocol,
  }) {
    final pending = [..._pending.values];
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(BergamotWorkerException(kind, message));
    }
  }

  static JSAny? _toJs(Object? value) => switch (value) {
    null => null,
    final String text => text.toJS,
    final bool flag => flag.toJS,
    final num number => number.toJS,
    final Uint8List bytes => bytes.toJS,
    final List<Object?> list => [for (final item in list) _toJs(item)].toJS,
    final Map<Object?, Object?> map => _object(map),
    _ => throw ArgumentError.value(value, 'value', 'Not sendable'),
  };

  static JSObject _object(Map<Object?, Object?> map) {
    final object = JSObject();
    for (final MapEntry(:key, :value) in map.entries) {
      object['$key'] = _toJs(value);
    }
    return object;
  }
}

@JS('navigator')
external JSObject? get _navigator;

/// Asks the browser to keep this site's storage (the offline models) under
/// storage pressure: `navigator.storage.persist()`. True when it will
/// (Chrome decides by itself; Firefox asks the user). Never throws.
Future<bool> requestPersistentBrowserStorage() async {
  try {
    final storage = _navigator?['storage'];
    if (storage == null || !storage.isA<JSObject>()) return false;
    final object = storage as JSObject;
    if (!object.has('persist')) return false;
    final granted = await object
        .callMethod<JSPromise<JSBoolean>>('persist'.toJS)
        .toDart;
    return granted.toDart;
  } on Object {
    return false;
  }
}
