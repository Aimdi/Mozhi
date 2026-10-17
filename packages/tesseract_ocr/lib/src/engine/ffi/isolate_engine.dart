import 'dart:async';
import 'dart:isolate';

import 'package:tesseract_ocr/src/engine/ffi/native_engine.dart';
import 'package:tesseract_ocr/src/engine/ocr_engine.dart';

/// [OcrEngine] running the native engine in one long-lived background
/// isolate, so loading language data and recognition never block the UI
/// isolate.
///
/// The isolate starts on first use, keeps up to [maxLoaded] language sets
/// loaded (least recently used are unloaded first) and handles one request
/// at a time, in order. The pixels are moved to it without a copy
/// ([TransferableTypedData]). [dispose] stops it; a later call starts a new
/// one. If the isolate dies, pending requests fail with
/// [TesseractEngineException] and the next call starts a new one.
final class IsolateTesseractEngine implements OcrEngine {
  new({this.libraryPath, this.maxLoaded = 2});

  /// Explicit path of `libmozhi_tesseract.so` (desktop tests); null uses
  /// `$TESSERACT_LIBRARY_PATH` or the library bundled with the app.
  final String? libraryPath;

  final int maxLoaded;

  Future<_Worker>? _worker;

  @override
  Future<OcrResult> recognize(
    OcrImage image, {
    required String dataPath,
    required List<String> languages,
  }) async {
    final worker = await _start();
    final result = await worker.request(
      _Recognize(
        TransferableTypedData.fromList([image.pixels]),
        width: image.width,
        height: image.height,
        bytesPerPixel: image.bytesPerPixel,
        bytesPerLine: image.bytesPerLine,
        dataPath: dataPath,
        languages: List.unmodifiable(languages),
      ),
    );
    return result! as OcrResult;
  }

  @override
  Future<void> release() async {
    final worker = _worker;
    if (worker == null) return;
    try {
      await (await worker).request(const _Release());
    } on TesseractEngineException {
      // It failed to start or died: nothing is loaded.
    }
  }

  @override
  Future<void> dispose() async {
    final worker = _worker;
    _worker = null;
    if (worker == null) return;
    try {
      await (await worker).stop();
    } on TesseractEngineException {
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

    started = _Worker.spawn(libraryPath, maxLoaded, onExit: forget);
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
    int maxLoaded, {
    required void Function() onExit,
  }) async {
    final responses = ReceivePort('tesseract responses');
    final exits = ReceivePort('tesseract exit');
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _main,
        _Start(responses.sendPort, libraryPath, maxLoaded),
        debugName: 'tesseract',
        onExit: exits.sendPort,
        onError: exits.sendPort,
      );
    } on Object catch (error) {
      responses.close();
      exits.close();
      throw TesseractEngineException('Cannot start the OCR isolate: $error');
    }
    final stream = responses.asBroadcastStream();
    final exitEvents = exits.asBroadcastStream();
    // The isolate's SendPort, or why it could not start (an engine error,
    // or the isolate died before answering).
    final first = await Future.any([
      stream.first,
      exitEvents.first.then((event) => 'The OCR isolate exited: $event'),
    ]);
    if (first is! SendPort) {
      responses.close();
      exits.close();
      isolate.kill(priority: Isolate.immediate);
      throw TesseractEngineException(first is String ? first : '$first');
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
  final Map<int, Completer<Object?>> _pending = {};
  var _nextId = 0;
  var _closed = false;

  Future<Object?> request(_Op op) {
    if (_closed) {
      return Future.error(
        const TesseractEngineException('The OCR isolate has stopped'),
      );
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
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
      completer.completeError(TesseractEngineException(error));
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
        const TesseractEngineException('The OCR isolate stopped'),
      );
    }
    _pending.clear();
    _onExit();
  }

  /// The isolate's entry point: owns the [NativeTesseractEngine].
  static void _main(_Start start) {
    final NativeTesseractEngine engine;
    try {
      engine = NativeTesseractEngine.open(
        libraryPath: start.libraryPath,
        maxLoaded: start.maxLoaded,
      );
    } on TesseractEngineException catch (error) {
      start.responses.send(error.message);
      return;
    }
    final requests = RawReceivePort();
    void handle(Object? message) {
      if (message is! _Request) return;
      try {
        final result = switch (message.op) {
          final _Recognize op => engine.recognize(
            op.pixels.materialize().asUint8List(),
            width: op.width,
            height: op.height,
            bytesPerPixel: op.bytesPerPixel,
            bytesPerLine: op.bytesPerLine,
            dataPath: op.dataPath,
            languages: op.languages,
          ),
          _Release() => () {
            engine.release();
            return null;
          }(),
          _Shutdown() => () {
            engine.release();
            requests.close();
            return null;
          }(),
        };
        start.responses.send(_Response(message.id, result: result));
      } on TesseractEngineException catch (error) {
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
  const new(this.responses, this.libraryPath, this.maxLoaded);

  final SendPort responses;
  final String? libraryPath;
  final int maxLoaded;
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
  final String? error;
}

sealed class _Op {
  const new();
}

final class _Recognize extends _Op {
  const new(
    this.pixels, {
    required this.width,
    required this.height,
    required this.bytesPerPixel,
    required this.bytesPerLine,
    required this.dataPath,
    required this.languages,
  });

  final TransferableTypedData pixels;
  final int width;
  final int height;
  final int bytesPerPixel;
  final int bytesPerLine;
  final String dataPath;
  final List<String> languages;
}

final class _Release extends _Op {
  const new();
}

final class _Shutdown extends _Op {
  const new();
}
