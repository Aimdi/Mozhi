// Browser-side RPC channel to web/llama/worker.js (dart:js_interop only).
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:llama_engine/src/engine/web/llama_worker.dart';

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

final class _PendingCall {
  new(this.completer, this.onDelta);

  final Completer<Object?> completer;
  final void Function(String delta)? onDelta;
}

/// [LlamaWorkerChannel] backed by a dedicated browser `Worker` running
/// `web/llama/worker.js`.
final class JsLlamaWorkerChannel implements LlamaWorkerChannel {
  new([this.url = defaultLlamaWorkerUrl]);

  final String url;

  _Worker? _worker;
  var _nextId = 1;
  final Map<int, _PendingCall> _pending = {};

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
    void Function(String delta)? onDelta,
  ]) {
    final _Worker worker;
    try {
      worker = _worker ??= _start();
    } on Object catch (error) {
      return Future.error(
        LlamaWorkerException(
          LlamaWorkerErrorKind.unsupported,
          'Cannot start $url: $error',
        ),
      );
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = _PendingCall(completer, onDelta);
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
        LlamaWorkerException(
          LlamaWorkerErrorKind.protocol,
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
        final message = event['message'];
        _worker?.terminate();
        _worker = null;
        _failAll(
          message.isA<JSString>()
              ? (message! as JSString).toDart
              : 'The worker failed to start',
          kind: LlamaWorkerErrorKind.unsupported,
        );
      }).toJS;
  }

  void _receive(JSAny? data) {
    final message = data.dartify();
    if (message is! Map) return;
    final id = message['id'];
    if (id is! num) return;
    final callId = id.toInt();
    if (message.containsKey('delta')) {
      final delta = message['delta'];
      if (delta is String) _pending[callId]?.onDelta?.call(delta);
      return;
    }
    final pending = _pending.remove(callId);
    if (pending == null) return;
    if (message['ok'] == true) {
      pending.completer.complete(message['result']);
    } else {
      final error = message['error'];
      pending.completer.completeError(
        LlamaWorkerException(
          LlamaWorkerErrorKind.of(error is Map ? error['kind'] : null),
          error is Map ? '${error['message']}' : 'Unknown worker error',
        ),
      );
    }
  }

  void _failAll(
    String message, {
    LlamaWorkerErrorKind kind = LlamaWorkerErrorKind.protocol,
  }) {
    final pending = [..._pending.values];
    _pending.clear();
    for (final item in pending) {
      item.completer.completeError(LlamaWorkerException(kind, message));
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
