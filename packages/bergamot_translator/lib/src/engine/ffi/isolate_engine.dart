import 'dart:async';
import 'dart:isolate';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/ffi/native_engine.dart';
import 'package:bergamot_translator/src/model_manager.dart';

/// [BergamotEngine] running the native engine in one long-lived background
/// isolate, so model loading and translation never block the UI isolate.
///
/// The isolate starts on first use, keeps up to [maxLoadedModels] models
/// loaded (least recently used are unloaded first; a pivot needs two) and
/// handles one request at a time, in order. [dispose] stops it; a later
/// call starts a new one. If the isolate dies, pending requests fail with
/// [BergamotEngineException] and the next call starts a new one.
final class IsolateBergamotEngine implements BergamotEngine {
  new({this.libraryPath, this.maxLoadedModels = 3})
    : assert(maxLoadedModels >= 2, 'A pivot needs two loaded models');

  /// Explicit path of `libmozhi_bergamot.so` (desktop tests); null uses
  /// `$BERGAMOT_LIBRARY_PATH` or the library bundled with the app.
  final String? libraryPath;

  final int maxLoadedModels;

  Future<_Worker>? _worker;

  @override
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  }) async {
    final worker = await _start();
    return (await worker.request(_Translate(chain, text, html: html)))!;
  }

  @override
  Future<void> release(String key) async {
    final worker = _worker;
    if (worker == null) return;
    await (await worker).request(_Release(key));
  }

  @override
  Future<void> dispose() async {
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      await (await worker).stop();
    } on BergamotEngineException {
      // It failed to start or died already: nothing left to stop.
    }
  }

  Future<_Worker> _start() {
    final existing = _worker;
    if (existing != null) return existing;
    late final Future<_Worker> started;
    void forget() {
      // Let the next request start a fresh isolate.
      if (identical(_worker, started)) _worker = null;
    }

    started = _Worker.spawn(libraryPath, maxLoadedModels, onExit: forget);
    _worker = started;
    // A failed start must not stick: the next call tries again.
    unawaited(started.then<void>((_) {}, onError: (Object _) => forget()));
    return started;
  }
}

final class _Worker {
  new _(this._isolate, this._requests, this._responses, this._onExit) {
    _subscription = _responses.listen(_handle);
  }

  static Future<_Worker> spawn(
    String? libraryPath,
    int maxLoadedModels, {
    required void Function() onExit,
  }) async {
    final responses = ReceivePort('bergamot responses');
    final exits = ReceivePort('bergamot exit');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _main,
        _Start(responses.sendPort, libraryPath, maxLoadedModels),
        debugName: 'bergamot',
        onExit: exits.sendPort,
        onError: exits.sendPort,
      );
    } on Object catch (error) {
      responses.close();
      exits.close();
      throw BergamotEngineException('Cannot start the engine isolate: $error');
    }
    final stream = responses.asBroadcastStream();
    final exitEvents = exits.asBroadcastStream();
    // The isolate's SendPort, or why it could not start (an engine error,
    // or the isolate died before answering).
    final first = await Future.any([
      stream.first,
      exitEvents.first.then((event) => 'The engine isolate exited: $event'),
    ]);
    if (first is! SendPort) {
      responses.close();
      exits.close();
      throw BergamotEngineException(first is String ? first : '$first');
    }
    late final _Worker worker;
    worker = _Worker._(isolate, first, stream, () {
      exits.close();
      responses.close();
      onExit();
    });
    exitEvents.listen((_) => worker._died());
    return worker;
  }

  final Isolate _isolate;
  final SendPort _requests;
  final Stream<Object?> _responses;
  final void Function() _onExit;
  late final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<String?>> _pending = {};
  var _nextId = 0;
  var _closed = false;

  Future<String?> request(_Op op) {
    if (_closed) {
      return Future.error(
        const BergamotEngineException('The engine isolate has stopped'),
      );
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<String?>();
    _requests.send(_Request(id, op));
    return completer.future;
  }

  Future<void> stop() async {
    if (_closed) return;
    await request(const _Shutdown());
    _died();
  }

  void _handle(Object? message) {
    if (message is! _Response) return;
    final completer = _pending.remove(message.id);
    if (completer == null) return;
    final error = message.error;
    if (error != null) {
      completer.completeError(BergamotEngineException(error));
    } else {
      completer.complete(message.result);
    }
  }

  void _died() {
    if (_closed) return;
    _closed = true;
    unawaited(_subscription.cancel());
    _isolate.kill(priority: Isolate.immediate);
    for (final completer in _pending.values) {
      completer.completeError(
        const BergamotEngineException('The engine isolate stopped'),
      );
    }
    _pending.clear();
    _onExit();
  }

  /// The isolate's entry point: owns the [NativeEngine].
  static void _main(_Start start) {
    final NativeEngine engine;
    try {
      engine = NativeEngine.open(
        libraryPath: start.libraryPath,
        maxLoadedModels: start.maxLoadedModels,
      );
    } on BergamotEngineException catch (error) {
      start.responses.send(error.message);
      return;
    }
    final requests = RawReceivePort();
    void handle(Object? message) {
      if (message is! _Request) return;
      try {
        final result = switch (message.op) {
          _Translate(:final chain, :final text, :final html) =>
            engine.translate(chain, text, html: html),
          _Release(:final key) => () {
            engine.release(key);
            return null;
          }(),
          _Shutdown() => () {
            engine.dispose();
            requests.close();
            return null;
          }(),
        };
        start.responses.send(_Response(message.id, result: result));
      } on BergamotEngineException catch (error) {
        start.responses.send(_Response(message.id, error: error.message));
      } on Object catch (error) {
        start.responses.send(_Response(message.id, error: '$error'));
      }
    }

    requests.handler = handle;
    start.responses.send(requests.sendPort);
  }
}

final class _Start {
  const new(this.responses, this.libraryPath, this.maxLoadedModels);

  final SendPort responses;
  final String? libraryPath;
  final int maxLoadedModels;
}

final class _Request {
  const new(this.id, this.op);

  final int id;
  final _Op op;
}

final class _Response {
  const new(this.id, {this.result, this.error});

  final int id;
  final String? result;
  final String? error;
}

sealed class _Op {
  const new();
}

final class _Translate extends _Op {
  const new(this.chain, this.text, {required this.html});

  final List<ModelPaths> chain;
  final String text;
  final bool html;
}

final class _Release extends _Op {
  const new(this.key);

  final String key;
}

final class _Shutdown extends _Op {
  const new();
}
