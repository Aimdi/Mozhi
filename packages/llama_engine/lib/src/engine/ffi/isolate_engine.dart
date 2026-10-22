import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:llama_engine/src/engine/ffi/bindings.dart';
import 'package:llama_engine/src/engine/ffi/native_engine.dart';
import 'package:llama_engine/src/engine/llama_engine.dart';

/// Opens the native engine inside the worker isolate from the library
/// candidates, best first. Must be a top-level or static function (it is
/// sent to the isolate).
typedef LlamaNativeOpener = LlamaNative Function(List<String> libraries);

/// [LlamaEngine] running the native engine in one long-lived background
/// isolate, so model loading and generation never block the UI isolate.
///
/// The isolate starts on first use and handles one request at a time, in
/// order: a generation waits for the one before it. Each generation
/// streams its pieces through a port of its own as soon as the native
/// loop produces them, and has a cancel flag in native memory that this
/// isolate sets when the subscription is cancelled: the native engine
/// checks it between tokens and while processing the prompt (via ggml's
/// abort callback), so a cancel takes effect within milliseconds and never
/// touches another generation. [cancel] stops all of them (and, like
/// whisper's engine, every generation of the process through the native
/// global cancel). [dispose] stops the isolate; a later call starts a new
/// one. If the isolate dies, pending requests fail with
/// [LlamaEngineException] and the next call starts a new one.
final class IsolateLlamaEngine implements LlamaEngine {
  /// [libraries] are tried in order inside the isolate (see
  /// [LlamaBindings.candidates]); by default [libraryPath], else
  /// `$LLAMA_LIBRARY_PATH`, else the baseline library. [opener] replaces
  /// the native engine (tests).
  new({List<String>? libraries, String? libraryPath, LlamaNativeOpener? opener})
    : libraries = libraries ?? LlamaBindings.candidates(path: libraryPath),
      _opener = opener ?? NativeLlamaEngine.openFirst;

  /// The native libraries to try, best first.
  final List<String> libraries;

  final LlamaNativeOpener _opener;
  Future<_Worker>? _worker;
  final Set<_Generation> _generations = {};
  String? _loadedModelPath;
  LlamaBindings? _cancelBindings;
  String? _cancelLibrary;

  @override
  String? get loadedModelPath => _loadedModelPath;

  @override
  Future<LlamaModelInfo> load(
    String modelPath, {
    int contextSize = 4096,
    int threads = 0,
  }) async {
    final worker = await _start();
    final info = await worker.request(
      _Load(modelPath, contextSize: contextSize, threads: threads),
    );
    _loadedModelPath = modelPath;
    return info! as LlamaModelInfo;
  }

  @override
  Future<int> countTokens(List<LlamaChatMessage> messages) async {
    final worker = await _start();
    final count = await worker.request(_CountTokens(List.of(messages)));
    return count! as int;
  }

  @override
  Stream<String> generate(LlamaGenerateRequest request) {
    late final StreamController<String> controller;
    _Generation? generation;
    controller = StreamController<String>(
      onListen: () => generation = _run(request, controller),
      onCancel: () {
        final running = generation;
        if (running == null) return null;
        running
          ..stop()
          ..closed = true;
        return running.settled;
      },
    );
    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    for (final generation in _generations.toList()) {
      generation
        ..stop()
        ..close(const LlamaCancelledException());
    }
    final worker = _worker;
    if (worker == null) return;
    final started = await worker.then<_Worker?>(
      (worker) => worker,
      onError: (Object _) => null,
    );
    if (started == null) return;
    // Like whisper's engine: also abort what the native library runs right
    // now (the flags above already stop this engine's generations).
    try {
      if (_cancelLibrary != started.library) {
        _cancelBindings = LlamaBindings(LlamaBindings.open(started.library));
        _cancelLibrary = started.library;
      }
      _cancelBindings?.cancel();
    } on Object {
      // Without the library nothing can be running.
    }
  }

  @override
  Future<void> unload() async {
    final worker = _worker;
    if (worker == null) return;
    await (await worker).request(const _Unload());
    _loadedModelPath = null;
  }

  @override
  Future<void> dispose() async {
    final worker = _worker;
    _worker = null;
    _loadedModelPath = null;
    for (final generation in _generations.toList()) {
      generation
        ..stop()
        ..close(const LlamaCancelledException());
    }
    if (worker == null) return;
    try {
      await (await worker).stop();
    } on LlamaEngineException {
      // It failed to start or died already: nothing left to stop.
    }
  }

  _Generation _run(
    LlamaGenerateRequest request,
    StreamController<String> controller,
  ) {
    final generation = _Generation(controller, request.onFinish);
    _generations.add(generation);
    unawaited(
      generation.settled.whenComplete(() => _generations.remove(generation)),
    );
    unawaited(() async {
      final _Worker worker;
      try {
        worker = await _start();
      } on LlamaEngineException catch (error) {
        generation
          ..close(error)
          ..settle();
        return;
      }
      if (generation.stopped) {
        generation.settle();
        return;
      }
      worker.generate(
        generation,
        _Generate(
          messages: List.of(request.messages),
          sampling: request.sampling,
          maxTokens: request.maxTokens,
          jsonOutput: request.jsonOutput,
          stop: List.of(request.stop),
          output: generation.port.sendPort,
          cancelFlag: generation.flag.address,
        ),
      );
    }());
    return generation;
  }

  Future<_Worker> _start() {
    final existing = _worker;
    if (existing != null) return existing;
    late final Future<_Worker> started;
    void forget() {
      // Let the next request start a fresh isolate.
      if (identical(_worker, started)) {
        _worker = null;
        _loadedModelPath = null;
      }
    }

    started = _Worker.spawn(libraries, _opener, onExit: forget);
    _worker = started;
    // A failed start must not stick: the next call tries again.
    unawaited(started.then<void>((_) {}, onError: (Object _) => forget()));
    return started;
  }
}

/// One generation, on the caller's side.
final class _Generation {
  new(this.controller, this.onFinish) {
    port.listen(_handle);
  }

  final StreamController<String> controller;
  final void Function(LlamaGenerateStats stats)? onFinish;
  final ReceivePort port = ReceivePort('llama generation');

  /// Set to 1 to cancel; read by the worker and the native engine. Freed
  /// once the worker is done with the generation ([settle]).
  final Pointer<Int32> flag = calloc<Int32>();

  final Completer<void> _settled = Completer<void>();

  /// The stream is closed (the answer ended, failed or was abandoned).
  bool closed = false;

  bool stopped = false;

  /// Completes once the worker no longer uses the generation.
  Future<void> get settled => _settled.future;

  void stop() {
    if (stopped || _settled.isCompleted) return;
    stopped = true;
    flag.value = 1;
  }

  void close([Object? error]) {
    if (closed) return;
    closed = true;
    if (error != null) controller.addError(error);
    unawaited(controller.close());
  }

  void settle() {
    if (_settled.isCompleted) return;
    port.close();
    calloc.free(flag);
    _settled.complete();
  }

  void _handle(Object? message) {
    switch (message) {
      case final String piece:
        if (!closed) controller.add(piece);
      case final LlamaGenerateStats stats:
        if (!closed) {
          try {
            onFinish?.call(stats);
          } on Object catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
          close();
        }
        settle();
      case final LlamaEngineException error:
        close(error);
        settle();
    }
  }
}

final class _Worker {
  new _(
    this._isolate,
    this._requests,
    this._responses,
    this.library,
    this._onExit,
  ) {
    _subscription = _responses.listen(_handle);
  }

  static Future<_Worker> spawn(
    List<String> libraries,
    LlamaNativeOpener opener, {
    required void Function() onExit,
  }) async {
    final responses = ReceivePort('llama responses');
    final exits = ReceivePort('llama exit');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _main,
        _Start(responses.sendPort, libraries, opener),
        debugName: 'llama',
        onExit: exits.sendPort,
        onError: exits.sendPort,
      );
    } on Object catch (error) {
      responses.close();
      exits.close();
      throw LlamaEngineException('Cannot start the engine isolate: $error');
    }
    final stream = responses.asBroadcastStream();
    final exitEvents = exits.asBroadcastStream();
    // The isolate's port and library, or why it could not start (an engine
    // error, or the isolate died before answering).
    final first = await Future.any([
      stream.first,
      exitEvents.first.then((event) => 'The engine isolate exited: $event'),
    ]);
    if (first is! _Ready) {
      responses.close();
      exits.close();
      isolate.kill(priority: Isolate.immediate);
      throw LlamaEngineException(first is String ? first : '$first');
    }
    late final _Worker worker;
    worker = _Worker._(isolate, first.requests, stream, first.library, () {
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

  /// The native library the isolate opened.
  final String library;

  late final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<Object?>> _pending = {};
  final Set<_Generation> _generations = {};
  var _nextId = 0;
  var _closed = false;

  Future<Object?> request(_Op op) {
    if (_closed) {
      return Future.error(
        const LlamaEngineException('The engine isolate has stopped'),
      );
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    _requests.send(_Request(id, op));
    return completer.future;
  }

  void generate(_Generation generation, _Generate op) {
    if (_closed) {
      generation
        ..close(const LlamaEngineException('The engine isolate has stopped'))
        ..settle();
      return;
    }
    _generations.add(generation);
    unawaited(
      generation.settled.whenComplete(() => _generations.remove(generation)),
    );
    _requests.send(op);
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
    if (message.error case final error?) {
      completer.completeError(error);
    } else {
      completer.complete(message.result);
    }
  }

  void _died() {
    if (_closed) return;
    _closed = true;
    unawaited(_subscription.cancel());
    _isolate.kill(priority: Isolate.immediate);
    const stopped = LlamaEngineException('The engine isolate stopped');
    for (final completer in _pending.values) {
      completer.completeError(stopped);
    }
    _pending.clear();
    for (final generation in _generations.toList()) {
      generation
        ..close(stopped)
        ..settle();
    }
    _onExit();
  }

  /// The isolate's entry point: owns the [LlamaNative].
  static void _main(_Start start) {
    final LlamaNative native;
    try {
      native = start.opener(start.libraries);
    } on LlamaEngineException catch (error) {
      start.responses.send(error.message);
      return;
    } on Object catch (error) {
      start.responses.send('Cannot load the native engine: $error');
      return;
    }
    final requests = RawReceivePort();
    void handle(Object? message) {
      switch (message) {
        case final _Generate generate:
          _generate(native, generate);
        case _Request(:final id, :final op):
          try {
            final result = switch (op) {
              _Load(:final path, :final contextSize, :final threads) =>
                native.load(path, contextSize: contextSize, threads: threads),
              _CountTokens(:final messages) => native.countTokens(messages),
              _Unload() => () {
                native.unload();
                return null;
              }(),
              _Shutdown() => () {
                native.dispose();
                requests.close();
                return null;
              }(),
            };
            start.responses.send(_Response(id, result: result));
          } on LlamaEngineException catch (error) {
            start.responses.send(_Response(id, error: error));
          } on Object catch (error) {
            start.responses.send(
              _Response(id, error: LlamaEngineException('$error')),
            );
          }
      }
    }

    requests.handler = handle;
    start.responses.send(_Ready(requests.sendPort, native.library));
  }

  /// Runs one generation, sending each piece to its port as soon as the
  /// native loop returns it, then the statistics (done) or the error. The
  /// last message is sent after the native generation ended, so the caller
  /// may free the cancel flag when it arrives.
  static void _generate(LlamaNative native, _Generate op) {
    final flag = Pointer<Int32>.fromAddress(op.cancelFlag);
    bool cancelled() => op.cancelFlag != 0 && flag.value != 0;
    if (cancelled()) {
      op.output.send(const LlamaCancelledException());
      return;
    }
    Object last;
    try {
      native.begin(
        LlamaGenerateRequest(
          messages: op.messages,
          sampling: op.sampling,
          maxTokens: op.maxTokens,
          jsonOutput: op.jsonOutput,
          stop: op.stop,
        ),
        cancelFlag: op.cancelFlag,
      );
      try {
        for (;;) {
          if (cancelled()) throw const LlamaCancelledException();
          final piece = native.next();
          if (piece == null) break;
          op.output.send(piece);
        }
        last = native.stats();
      } finally {
        native.end();
      }
    } on LlamaEngineException catch (error) {
      last = error;
    } on Object catch (error) {
      last = LlamaEngineException('generate: $error');
    }
    op.output.send(last);
  }
}

final class _Start {
  const new(this.responses, this.libraries, this.opener);

  final SendPort responses;
  final List<String> libraries;
  final LlamaNativeOpener opener;
}

final class _Ready {
  const new(this.requests, this.library);

  final SendPort requests;
  final String library;
}

final class _Request {
  const new(this.id, this.op);

  final int id;
  final _Op op;
}

final class _Response {
  const new(this.id, {this.result, this.error});

  final int id;
  final Object? result;
  final LlamaEngineException? error;
}

sealed class _Op {
  const new();
}

final class _Load extends _Op {
  const new(this.path, {required this.contextSize, required this.threads});

  final String path;
  final int contextSize;
  final int threads;
}

final class _CountTokens extends _Op {
  const new(this.messages);

  final List<LlamaChatMessage> messages;
}

final class _Unload extends _Op {
  const new();
}

final class _Shutdown extends _Op {
  const new();
}

/// A generation request (sent on its own: the worker answers through
/// [output], not with a [_Response]).
final class _Generate {
  const new({
    required this.messages,
    required this.sampling,
    required this.maxTokens,
    required this.jsonOutput,
    required this.stop,
    required this.output,
    required this.cancelFlag,
  });

  final List<LlamaChatMessage> messages;
  final LlamaSampling sampling;
  final int maxTokens;
  final bool jsonOutput;
  final List<String> stop;
  final SendPort output;

  /// Address of the generation's cancel flag (an `int32`).
  final int cancelFlag;
}
