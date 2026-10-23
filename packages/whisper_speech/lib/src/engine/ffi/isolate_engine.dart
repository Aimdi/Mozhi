import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:whisper_speech/src/engine/ffi/bindings.dart';
import 'package:whisper_speech/src/engine/ffi/native_engine.dart';
import 'package:whisper_speech/src/engine/whisper_engine.dart';

/// Picks the library a worker isolate opens from the engine's explicit
/// `libraryPath` (default [WhisperBindings.resolve]: the fastest variant
/// the CPU runs). Runs in the worker isolate.
typedef WhisperLibraryResolver = String Function(String? libraryPath);

String _resolveLibrary(String? libraryPath) =>
    WhisperBindings.resolve(path: libraryPath);

/// [WhisperEngine] running the native engine in one long-lived background
/// isolate, so model loading and transcription never block the UI isolate.
///
/// The isolate starts on first use, opens the library its
/// `resolveLibrary` picks (the variant for the CPU:
/// [WhisperBindings.resolve]), keeps the
/// last used model loaded and handles one request at a time, in order.
/// [cancel] aborts the running transcription in that same library (it
/// checks between computation steps) and fails every waiting one at once.
/// [dispose] stops the isolate; a later call starts a new one. If the
/// isolate dies, pending requests fail with [WhisperEngineException] and
/// the next call starts a new one.
final class IsolateWhisperEngine implements WhisperEngine {
  new({this.libraryPath, WhisperLibraryResolver? resolveLibrary})
    : _resolve = resolveLibrary ?? _resolveLibrary;

  /// Explicit path of `libmozhi_whisper.so` (desktop tests); null uses
  /// `$WHISPER_LIBRARY_PATH` or the library bundled with the app for this
  /// CPU.
  final String? libraryPath;

  final WhisperLibraryResolver _resolve;
  Future<_Worker>? _worker;
  String? _cancelLibrary;
  WhisperBindings? _cancelBindings;

  /// The library the running worker isolate opened (a file name in the
  /// APK, or a path); null while none runs.
  Future<String?> get library => _libraryOf(_worker);

  @override
  Future<WhisperTranscription> transcribe(
    String modelPath,
    Float32List samples, {
    String? language,
    int threads = 0,
  }) async {
    final worker = await _start();
    final result = await worker.request(
      _Transcribe(
        modelPath,
        TransferableTypedData.fromList([samples]),
        language: language,
        threads: threads,
      ),
      cancellable: true,
    );
    return result! as WhisperTranscription;
  }

  @override
  Future<void> cancel() async {
    final worker = _worker;
    if (worker == null) return;
    final started = await worker.then<_Worker?>(
      (worker) => worker,
      onError: (Object _) => null,
    );
    if (started == null) return;
    // The worker isolate is busy inside the native call: abort it from
    // here, in the library it opened (loaded in the process already; a
    // variant has its own cancel state).
    try {
      if (_cancelLibrary != started.library) {
        _cancelBindings = WhisperBindings(
          WhisperBindings.open(started.library),
        );
        _cancelLibrary = started.library;
      }
      _cancelBindings?.cancel();
    } on Object {
      // Without the library nothing can be running.
    }
    started.cancelPending();
  }

  @override
  Future<void> release(String modelPath) async {
    final worker = _worker;
    if (worker == null) return;
    await (await worker).request(_Release(modelPath));
  }

  @override
  Future<void> dispose() async {
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      await (await worker).stop();
    } on WhisperEngineException {
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

    started = _Worker.spawn(libraryPath, _resolve, onExit: forget);
    _worker = started;
    // A failed start must not stick: the next call tries again.
    unawaited(started.then<void>((_) {}, onError: (Object _) => forget()));
    return started;
  }
}

/// [WhisperVadEngine] running the native voice activity detector in its
/// own long-lived background isolate (a transcription in
/// [IsolateWhisperEngine]'s isolate takes seconds; detection has to keep up
/// with the microphone meanwhile).
///
/// The isolate starts on first use and handles one request at a time, in
/// order. [dispose] stops it; a later call starts a new one (with a new
/// stream). If the isolate dies, pending requests fail with
/// [WhisperEngineException] and the next call starts a new one.
final class IsolateWhisperVadEngine implements WhisperVadEngine {
  new({this.libraryPath, WhisperLibraryResolver? resolveLibrary})
    : _resolve = resolveLibrary ?? _resolveLibrary;

  /// Explicit path of `libmozhi_whisper.so` (desktop tests); null uses
  /// `$WHISPER_LIBRARY_PATH` or the library bundled with the app for this
  /// CPU.
  final String? libraryPath;

  final WhisperLibraryResolver _resolve;
  Future<_Worker>? _worker;

  /// The library the running worker isolate opened; null while none runs.
  Future<String?> get library => _libraryOf(_worker);

  @override
  Future<WhisperVadFrames> detect(String modelPath, Float32List samples) async {
    final worker = await _start();
    final result = await worker.request(
      _VadDetect(modelPath, TransferableTypedData.fromList([samples])),
    );
    return result! as WhisperVadFrames;
  }

  @override
  Future<void> reset() async {
    final worker = _worker;
    if (worker == null) return;
    await (await worker).request(const _VadReset());
  }

  @override
  Future<void> release(String modelPath) async {
    final worker = _worker;
    if (worker == null) return;
    await (await worker).request(_Release(modelPath));
  }

  @override
  Future<void> dispose() async {
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      await (await worker).stop();
    } on WhisperEngineException {
      // It failed to start or died already: nothing left to stop.
    }
  }

  Future<_Worker> _start() {
    final existing = _worker;
    if (existing != null) return existing;
    late final Future<_Worker> started;
    void forget() {
      if (identical(_worker, started)) _worker = null;
    }

    started = _Worker.spawn(
      libraryPath,
      _resolve,
      onExit: forget,
      name: 'whisper vad',
    );
    _worker = started;
    unawaited(started.then<void>((_) {}, onError: (Object _) => forget()));
    return started;
  }
}

Future<String?> _libraryOf(Future<_Worker>? worker) async {
  if (worker == null) return null;
  try {
    return (await worker).library;
  } on WhisperEngineException {
    return null;
  }
}

final class _Worker {
  new _(
    this._isolate,
    this._requests,
    this.library,
    this._responses,
    this._onExit,
  ) {
    _subscription = _responses.listen(_handle);
  }

  static Future<_Worker> spawn(
    String? libraryPath,
    WhisperLibraryResolver resolve, {
    required void Function() onExit,
    String name = 'whisper',
  }) async {
    final responses = ReceivePort('$name responses');
    final exits = ReceivePort('$name exit');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _main,
        _Start(responses.sendPort, libraryPath, resolve),
        debugName: name,
        onExit: exits.sendPort,
        onError: exits.sendPort,
      );
    } on Object catch (error) {
      responses.close();
      exits.close();
      throw WhisperEngineException('Cannot start the engine isolate: $error');
    }
    final stream = responses.asBroadcastStream();
    final exitEvents = exits.asBroadcastStream();
    // The isolate's SendPort and library, or why it could not start (an
    // engine error, or the isolate died before answering).
    final first = await Future.any([
      stream.first,
      exitEvents.first.then((event) => 'The engine isolate exited: $event'),
    ]);
    if (first is! _Ready) {
      responses.close();
      exits.close();
      throw WhisperEngineException(first is String ? first : '$first');
    }
    late final _Worker worker;
    worker = _Worker._(isolate, first.requests, first.library, stream, () {
      exits.close();
      responses.close();
      onExit();
    });
    exitEvents.listen((_) => worker._died());
    return worker;
  }

  final Isolate _isolate;
  final SendPort _requests;

  /// The library the isolate opened.
  final String library;

  final Stream<Object?> _responses;
  final void Function() _onExit;
  late final StreamSubscription<Object?> _subscription;
  final Map<int, Completer<Object?>> _pending = {};
  final Set<int> _cancellable = {};
  var _nextId = 0;
  var _closed = false;

  Future<Object?> request(_Op op, {bool cancellable = false}) {
    if (_closed) {
      return Future.error(
        const WhisperEngineException('The engine isolate has stopped'),
      );
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    if (cancellable) _cancellable.add(id);
    _requests.send(_Request(id, op));
    return completer.future;
  }

  /// Fails every cancellable request at once; their late answers are
  /// dropped.
  void cancelPending() {
    for (final id in _cancellable) {
      _pending.remove(id)?.completeError(const WhisperCancelledException());
    }
    _cancellable.clear();
  }

  Future<void> stop() async {
    if (_closed) return;
    await request(const _Shutdown());
    _died();
  }

  void _handle(Object? message) {
    if (message is! _Response) return;
    _cancellable.remove(message.id);
    final completer = _pending.remove(message.id);
    if (completer == null) return;
    if (message.cancelled) {
      completer.completeError(const WhisperCancelledException());
    } else if (message.error case final error?) {
      completer.completeError(WhisperEngineException(error));
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
        const WhisperEngineException('The engine isolate stopped'),
      );
    }
    _pending.clear();
    _cancellable.clear();
    _onExit();
  }

  /// The isolate's entry point: picks the library and owns the
  /// [NativeWhisperEngine].
  static void _main(_Start start) {
    final String library;
    final NativeWhisperEngine engine;
    try {
      library = start.resolve(start.libraryPath);
      engine = NativeWhisperEngine.open(libraryPath: library);
    } on WhisperEngineException catch (error) {
      start.responses.send(error.message);
      return;
    } on Object catch (error) {
      start.responses.send('Cannot load the native engine: $error');
      return;
    }
    final requests = RawReceivePort();
    void handle(Object? message) {
      if (message is! _Request) return;
      try {
        final result = switch (message.op) {
          _Transcribe(
            :final modelPath,
            :final samples,
            :final language,
            :final threads,
          ) =>
            engine.transcribe(
              modelPath,
              samples.materialize().asFloat32List(),
              language: language,
              threads: threads,
            ),
          _VadDetect(:final modelPath, :final samples) => engine.detectSpeech(
            modelPath,
            samples.materialize().asFloat32List(),
          ),
          _VadReset() => () {
            engine.resetSpeech();
            return null;
          }(),
          _Release(:final modelPath) => () {
            engine.release(modelPath);
            return null;
          }(),
          _Shutdown() => () {
            engine.dispose();
            requests.close();
            return null;
          }(),
        };
        start.responses.send(_Response(message.id, result: result));
      } on WhisperCancelledException {
        start.responses.send(_Response(message.id, cancelled: true));
      } on WhisperEngineException catch (error) {
        start.responses.send(_Response(message.id, error: error.message));
      } on Object catch (error) {
        start.responses.send(_Response(message.id, error: '$error'));
      }
    }

    requests.handler = handle;
    start.responses.send(_Ready(requests.sendPort, library));
  }
}

final class _Start {
  const new(this.responses, this.libraryPath, this.resolve);

  final SendPort responses;
  final String? libraryPath;
  final WhisperLibraryResolver resolve;
}

/// The worker's first message: where to send requests, and the library it
/// opened.
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
  const new(this.id, {this.result, this.error, this.cancelled = false});

  final int id;
  final Object? result;
  final String? error;
  final bool cancelled;
}

sealed class _Op {
  const new();
}

final class _Transcribe extends _Op {
  const new(
    this.modelPath,
    this.samples, {
    required this.language,
    required this.threads,
  });

  final String modelPath;
  final TransferableTypedData samples;
  final String? language;
  final int threads;
}

final class _VadDetect extends _Op {
  const new(this.modelPath, this.samples);

  final String modelPath;
  final TransferableTypedData samples;
}

final class _VadReset extends _Op {
  const new();
}

final class _Release extends _Op {
  const new(this.modelPath);

  final String modelPath;
}

final class _Shutdown extends _Op {
  const new();
}
