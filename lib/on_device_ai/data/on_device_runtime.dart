import 'dart:async';
import 'dart:math' as math;

import 'package:llama_engine/llama_engine.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';

/// A model loaded for a request ([OnDeviceRuntime.run]).
typedef LoadedOnDeviceModel = ({
  /// The catalogue entry.
  LlamaCatalogModel model,

  /// The engine it is loaded in.
  LlamaEngine engine,

  /// Tokens the prompt and the reply share (the catalogue's context,
  /// at most what the model was trained with).
  int contextSize,
});

/// The engine behind [OnDeviceAi]: one model in memory and one request at
/// a time (requests queue, in order), its status, and unloading.
///
/// [run] loads the model a request needs (unloading any other) and holds
/// the engine until the request is done; a model is unloaded
/// [idleUnloadAfter] after the last request ends, and [unload] waits for
/// the running and queued requests.
class OnDeviceRuntime {
  new({
    required this.engine,
    required this.catalog,
    required this._pathOf,
    this.idleUnloadAfter = OnDeviceAi.defaultIdleUnloadAfter,
  });

  final LlamaEngine engine;

  /// The models that can be installed.
  final LlamaModelCatalog catalog;

  /// The path of an installed model's file (null when it is not
  /// installed).
  final Future<String?> Function(String id) _pathOf;

  /// How long a model stays loaded after the last request.
  final Duration idleUnloadAfter;

  /// The end of the last queued job.
  Future<void> _tail = Future.value();

  /// Requests running or queued.
  int _busy = 0;
  bool _unloadWhenIdle = false;
  bool _disposed = false;
  Timer? _idleTimer;

  /// The model in memory: its id and context size.
  ({String id, String path, int contextSize})? _loaded;

  OnDeviceAiStatus _status = const OnDeviceAiIdle();
  final _statusController = StreamController<OnDeviceAiStatus>.broadcast();

  /// See [OnDeviceAi.status].
  Stream<OnDeviceAiStatus> get status => _statusController.stream;

  /// The latest [status].
  OnDeviceAiStatus get currentStatus => _status;

  /// The id of the model in memory, if any.
  String? get loadedModelId => _loaded?.id;

  /// The installed models of the [catalog].
  Future<List<LlamaCatalogModel>> installed() async => [
    for (final model in catalog.models)
      if (await _pathOf(model.id) != null) model,
  ];

  /// Runs [action] alone (after the requests before it) with model [id]
  /// loaded: [OnDeviceAiLoading] while it loads, then
  /// [OnDeviceAiGenerating] (unless not [generating]: a warm-up).
  /// [isCancelled] is asked before the model loads: a request cancelled
  /// while it waited runs nothing and yields null.
  ///
  /// Fails with an [LlmApiException] when the model is not installed or
  /// cannot be loaded ([OnDeviceAiError]).
  Future<T?> run<T>(
    String id,
    Future<T> Function(LoadedOnDeviceModel loaded) action, {
    bool generating = true,
    bool Function()? isCancelled,
  }) {
    if (_disposed) return Future.error(_disposedError);
    _idleTimer?.cancel();
    _busy++;
    final result = _tail.then((_) async {
      // Disposed while it waited: the engine must not start again.
      if (_disposed) throw _disposedError;
      if (isCancelled?.call() ?? false) return null;
      final loaded = await _load(id);
      if (generating) _setStatus(OnDeviceAiGenerating(id));
      try {
        return await action(loaded);
      } on Object catch (error) {
        _setStatus(OnDeviceAiError(id, error));
        rethrow;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result.whenComplete(_finished);
  }

  static const _disposedError = LlmApiException(
    'On-device AI is no longer available.',
  );

  /// Frees the model's memory: now when nothing runs, else once the
  /// running and queued requests are done.
  Future<void> unload() async {
    if (_disposed) return;
    if (_busy > 0) {
      _unloadWhenIdle = true;
      return;
    }
    _idleTimer?.cancel();
    if (_loaded == null) return;
    final done = _tail.then((_) => _unloadNow());
    _tail = done.then<void>((_) {}, onError: (Object _) {});
    await _tail;
  }

  /// Stops a running generation, unloads the model and stops the engine.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _idleTimer?.cancel();
    try {
      await engine.cancel();
      await engine.dispose();
    } on Object {
      // Nothing left to free.
    }
    _loaded = null;
    await _statusController.close();
  }

  Future<LoadedOnDeviceModel> _load(String id) async {
    final model = catalog.model(id);
    final path = model == null ? null : await _pathOf(id);
    if (model == null || path == null) {
      final error = LlmApiException(
        'The on-device model "$id" is not installed.',
      );
      _setStatus(OnDeviceAiError(id, error));
      throw error;
    }
    final loaded = _loaded;
    if (loaded != null &&
        loaded.id == id &&
        loaded.path == path &&
        engine.loadedModelPath == path) {
      return (model: model, engine: engine, contextSize: loaded.contextSize);
    }
    _setStatus(OnDeviceAiLoading(id));
    final LlamaModelInfo info;
    try {
      info = await engine.load(path, contextSize: model.contextSize);
    } on Object catch (cause) {
      _loaded = null;
      final error = LlmApiException(
        'The on-device model could not be loaded. Free some memory, or '
        'download the model again.',
        body: '$cause',
      );
      _setStatus(OnDeviceAiError(id, error));
      throw error;
    }
    // The loaded context (the catalogue's, at most the trained one).
    final trained = info.contextLength;
    final contextSize = info.contextSize > 0
        ? info.contextSize
        : trained > 0
        ? math.min(model.contextSize, trained)
        : model.contextSize;
    _loaded = (id: id, path: path, contextSize: contextSize);
    return (model: model, engine: engine, contextSize: contextSize);
  }

  Future<void> _unloadNow() async {
    _loaded = null;
    try {
      await engine.unload();
    } on Object {
      // The engine frees what it can; the next request loads again.
    }
  }

  void _finished() {
    _busy--;
    if (_busy > 0 || _disposed) return;
    _setStatus(const OnDeviceAiIdle());
    if (_unloadWhenIdle) {
      _unloadWhenIdle = false;
      unawaited(unload());
      return;
    }
    if (_loaded != null) {
      _idleTimer = Timer(idleUnloadAfter, () => unawaited(unload()));
    }
  }

  void _setStatus(OnDeviceAiStatus status) {
    if (_disposed || status == _status) return;
    _status = status;
    _statusController.add(status);
  }
}
