// coverage:ignore-file
// Browser Web Worker bridge for `web/backup/argon2_worker.js` (dart:js_interop
// only; compiled for the web alone, see argon2_worker.dart).
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory(JSString url);

  external void postMessage(JSAny? message);
  external JSFunction? get onmessage;
  external set onmessage(JSFunction? handler);
  external JSFunction? get onmessageerror;
  external set onmessageerror(JSFunction? handler);
  external JSFunction? get onerror;
  external set onerror(JSFunction? handler);
  external void terminate();
}

extension type _MessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

@JS('document.baseURI')
external String? get _baseUri;

const _workerRelativePath = 'backup/argon2_worker.js';
const _workerTimeout = Duration(seconds: 60);

final _Argon2WorkerClient _client = _Argon2WorkerClient();

/// Runs RFC 9106 Argon2id inside `web/backup/argon2_worker.js` off the UI
/// thread. Returns `null` when `Worker` is unavailable, stalls, or fails,
/// so callers can fall back to inline `DartArgon2id`.
Future<Uint8List?> deriveArgon2idInWorker({
  required List<int> passphraseBytes,
  required Uint8List saltBytes,
  required int memoryKiB,
  required int iterations,
  required int parallelism,
  required int hashLength,
}) => _client.derive(
  passphraseBytes: passphraseBytes,
  saltBytes: saltBytes,
  memoryKiB: memoryKiB,
  iterations: iterations,
  parallelism: parallelism,
  hashLength: hashLength,
);

final class _PendingRequest {
  new(this.completer, this.timer);

  final Completer<Uint8List?> completer;
  final Timer timer;
}

final class _Argon2WorkerClient {
  _Worker? _worker;
  var _nextId = 1;
  final Map<int, _PendingRequest> _pending = {};

  Future<Uint8List?> derive({
    required List<int> passphraseBytes,
    required Uint8List saltBytes,
    required int memoryKiB,
    required int iterations,
    required int parallelism,
    required int hashLength,
  }) {
    if (!globalContext.getProperty<JSAny?>('Worker'.toJS).isA<JSFunction>()) {
      return Future.value();
    }
    final _Worker worker;
    try {
      worker = _worker ??= _start();
    } on Object {
      return Future.value();
    }
    final id = _nextId++;
    final completer = Completer<Uint8List?>();
    final timer = Timer(_workerTimeout, () {
      if (_pending.remove(id) == null) return;
      _resetWorker();
      if (!completer.isCompleted) completer.complete(null);
    });
    _pending[id] = _PendingRequest(completer, timer);
    final message = JSObject()
      ..['id'] = id.toJS
      ..['op'] = 'derive'.toJS
      ..['passphraseBytes'] = Uint8List.fromList(passphraseBytes).toJS
      ..['saltBytes'] = Uint8List.fromList(saltBytes).toJS
      ..['memoryKiB'] = memoryKiB.toJS
      ..['iterations'] = iterations.toJS
      ..['parallelism'] = parallelism.toJS
      ..['hashLength'] = hashLength.toJS;
    try {
      worker.postMessage(message);
    } on Object {
      timer.cancel();
      _pending.remove(id);
      return Future.value();
    }
    return completer.future;
  }

  _Worker _start() {
    final url = _resolveWorkerUrl();
    return _Worker(url.toJS)
      ..onmessage = ((_MessageEvent event) => _receive(event.data)).toJS
      ..onmessageerror = ((JSObject _) => _resetWorker()).toJS
      ..onerror = ((JSObject _) => _resetWorker()).toJS;
  }

  void _resetWorker() {
    _worker?.terminate();
    _worker = null;
    _failAll();
  }

  void _receive(JSAny? data) {
    if (data == null || !data.isA<JSObject>()) return;
    final object = data as JSObject;
    final rawId = object['id'];
    if (rawId == null || !rawId.isA<JSNumber>()) return;
    final request = _pending.remove((rawId as JSNumber).toDartInt);
    if (request == null) return;
    request.timer.cancel();
    final completer = request.completer;
    if (completer.isCompleted) return;

    final rawOk = object['ok'];
    if (rawOk != null &&
        rawOk.isA<JSBoolean>() &&
        (rawOk as JSBoolean).toDart) {
      final rawKey = object['key'];
      if (rawKey != null && rawKey.isA<JSUint8Array>()) {
        completer.complete((rawKey as JSUint8Array).toDart);
        return;
      }
    }
    completer.complete(null);
  }

  void _failAll() {
    final pending = [..._pending.values];
    _pending.clear();
    for (final request in pending) {
      request.timer.cancel();
      if (!request.completer.isCompleted) request.completer.complete(null);
    }
  }

  static String _resolveWorkerUrl() {
    final base = _baseUri;
    final resolved = base == null
        ? null
        : Uri.tryParse(base)?.resolve(_workerRelativePath);
    return resolved?.toString() ?? _workerRelativePath;
  }
}
