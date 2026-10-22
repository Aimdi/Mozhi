import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:llama_engine/src/engine/ffi/bindings.dart';
import 'package:llama_engine/src/engine/llama_engine.dart';

/// The synchronous engine the worker isolate drives: one loaded model and
/// at most one generation. [NativeLlamaEngine] in the app; tests use fakes
/// to check the isolate protocol without the library.
abstract interface class LlamaNative {
  /// The library this engine opened (the main isolate opens the same one
  /// to cancel).
  String get library;

  /// Engine version and the CPU variant, for diagnostics.
  String get engine;

  /// Path of the loaded model, if any.
  String? get loadedModelPath;

  /// Loads [path] unless it is loaded with the same settings already;
  /// unloads any other model first.
  LlamaModelInfo load(
    String path, {
    required int contextSize,
    required int threads,
  });

  /// Frees the model, if any.
  void unload();

  /// Tokens of [messages] formatted with the chat template.
  int countTokens(List<LlamaChatMessage> messages);

  /// Starts a generation; [cancelFlag] is the address of an `int32` that
  /// another isolate sets to non-zero to cancel it (0: none).
  void begin(LlamaGenerateRequest request, {int cancelFlag = 0});

  /// The next piece of text, or null at the end.
  String? next();

  /// The statistics of the current or last generation.
  LlamaGenerateStats stats();

  /// Ends the generation (if any).
  void end();

  /// Frees everything.
  void dispose();
}

/// Synchronous access to `libmozhi_llama` with one loaded model. Blocks
/// the calling isolate: only used inside the engine isolate (see
/// `IsolateLlamaEngine`).
final class NativeLlamaEngine implements LlamaNative {
  new(this._bindings, {required this.library});

  /// Opens the first of [libraries] that loads and has the expected ABI
  /// (the fastest CPU variant first, the baseline last: see
  /// [LlamaBindings.candidates]).
  factory openFirst(List<String> libraries) {
    final failures = <String>[];
    for (final library in libraries) {
      final LlamaBindings bindings;
      try {
        bindings = LlamaBindings(LlamaBindings.open(library));
      } on Object catch (error) {
        failures.add('$library: $error');
        continue;
      }
      final abi = bindings.abiVersion();
      if (abi != LlamaBindings.expectedAbiVersion) {
        failures.add(
          '$library: ABI $abi, expected ${LlamaBindings.expectedAbiVersion}',
        );
        continue;
      }
      return NativeLlamaEngine(bindings, library: library);
    }
    throw LlamaEngineException(
      'Cannot load the native engine: ${failures.join('; ')}',
    );
  }

  /// Opens [libraryPath], else `$LLAMA_LIBRARY_PATH`, else the baseline
  /// library from the system search path (the APK on Android).
  factory open({String? libraryPath}) =>
      NativeLlamaEngine.openFirst(LlamaBindings.candidates(path: libraryPath));

  final LlamaBindings _bindings;

  @override
  final String library;

  Pointer<NativeLlamaModel> _model = nullptr;
  String? _loadedPath;
  int _contextSize = 0;
  int _threads = 0;
  LlamaModelInfo? _info;
  bool _generating = false;
  Pointer<Utf8> _piece = nullptr;

  /// Engine version, e.g. `llama.cpp 0.6.0 (ggml 0.26.0, CPU armv8-a)`.
  String get version => _bindings.version().toDartString();

  /// What the CPU backend uses, e.g. `armv8-a: NEON ARM_FMA`.
  String get cpuFeatures => _bindings.cpuFeatures().toDartString();

  @override
  String get engine => '$version; $cpuFeatures';

  @override
  String? get loadedModelPath => _loadedPath;

  @override
  LlamaModelInfo load(
    String path, {
    required int contextSize,
    required int threads,
  }) {
    final loaded = _info;
    if (loaded != null &&
        _loadedPath == path &&
        _contextSize == contextSize &&
        _threads == threads) {
      return loaded;
    }
    unload();
    final model = using(
      (arena) => _bindings.modelLoad(
        path.toNativeUtf8(allocator: arena),
        threads,
        contextSize,
        1,
      ),
    );
    if (model == nullptr) _fail('load');
    final LlamaModelInfo info;
    try {
      info = LlamaModelInfo.fromNative(
        jsonDecode(_takeString(_bindings.modelInfo(model), 'info'))
            as Map<String, Object?>,
        engine: engine,
      );
    } on Object {
      _bindings.modelFree(model);
      rethrow;
    }
    _model = model;
    _loadedPath = path;
    _contextSize = contextSize;
    _threads = threads;
    return _info = info;
  }

  @override
  void unload() {
    if (_model == nullptr) return;
    end();
    _bindings.modelFree(_model);
    _model = nullptr;
    _loadedPath = null;
    _info = null;
  }

  /// [messages] formatted with the model's chat template.
  String formatChat(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) {
    final model = _requireModel();
    return using((arena) {
      final roles = arena<Pointer<Utf8>>(
        messages.isEmpty ? 1 : messages.length,
      );
      final contents = arena<Pointer<Utf8>>(
        messages.isEmpty ? 1 : messages.length,
      );
      for (var i = 0; i < messages.length; i++) {
        roles[i] = messages[i].role.name.toNativeUtf8(allocator: arena);
        contents[i] = messages[i].content.toNativeUtf8(allocator: arena);
      }
      return _takeString(
        _bindings.chatFormat(
          model,
          roles,
          contents,
          messages.length,
          addAssistant ? 1 : 0,
        ),
        'chat template',
      );
    });
  }

  /// Tokens of [prompt] as the engine would tokenize it.
  int tokenCount(String prompt) {
    final model = _requireModel();
    final count = using(
      (arena) =>
          _bindings.tokenizeCount(model, prompt.toNativeUtf8(allocator: arena)),
    );
    if (count < 0) _fail('count tokens');
    return count;
  }

  @override
  int countTokens(List<LlamaChatMessage> messages) =>
      tokenCount(formatChat(messages));

  @override
  void begin(LlamaGenerateRequest request, {int cancelFlag = 0}) {
    final model = _requireModel();
    end();
    final prompt = formatChat(request.messages);
    final status = using((arena) {
      final params = arena<NativeLlamaParams>();
      final sampling = request.sampling;
      params.ref
        ..temperature = sampling.temperature
        ..topK = sampling.topK
        ..topP = sampling.topP
        ..minP = sampling.minP
        ..repeatPenalty = sampling.repeatPenalty
        ..repeatLastN = sampling.repeatLastN
        ..seed = (sampling.seed ?? LlamaBindings.randomSeed) & 0xFFFFFFFF
        ..maxTokens = request.maxTokens
        ..grammar = request.jsonOutput ? _bindings.jsonGrammar() : nullptr
        ..stopCount = request.stop.length
        ..cancelFlag = Pointer<Int32>.fromAddress(cancelFlag);
      final stops = arena<Pointer<Utf8>>(
        request.stop.isEmpty ? 1 : request.stop.length,
      );
      for (var i = 0; i < request.stop.length; i++) {
        stops[i] = request.stop[i].toNativeUtf8(allocator: arena);
      }
      params.ref.stop = stops;
      return _bindings.generateBegin(
        model,
        prompt.toNativeUtf8(allocator: arena),
        params,
      );
    });
    if (status == LlamaBindings.contextFull) {
      throw LlamaContextException(
        _lastError(),
        promptTokens: tokenCount(prompt),
        contextSize: _info?.contextSize,
      );
    }
    if (status != LlamaBindings.ok) _fail('generate');
    _generating = true;
  }

  @override
  String? next() {
    final model = _requireModel();
    if (!_generating) {
      throw const LlamaEngineException('generate: no generation is running');
    }
    if (_piece == nullptr) {
      _piece = calloc<Uint8>(LlamaBindings.pieceBufferSize).cast<Utf8>();
    }
    final length = _bindings.generateNext(
      model,
      _piece,
      LlamaBindings.pieceBufferSize,
    );
    if (length > 0) return _piece.toDartString(length: length);
    if (length == 0) return null;
    _fail('generate');
  }

  @override
  LlamaGenerateStats stats() {
    final model = _requireModel();
    return using((arena) {
      final stats = arena<NativeLlamaStats>();
      if (_bindings.generateStats(model, stats) != LlamaBindings.ok) {
        _fail('stats');
      }
      final ref = stats.ref;
      return LlamaGenerateStats(
        promptTokens: ref.promptTokens,
        generatedTokens: ref.generatedTokens,
        finishReason: ref.finishReason == LlamaBindings.finishLength
            ? LlamaFinishReason.length
            : LlamaFinishReason.stop,
        promptDuration: Duration(microseconds: (ref.promptMs * 1000).round()),
        generateDuration: Duration(
          microseconds: (ref.generateMs * 1000).round(),
        ),
      );
    });
  }

  @override
  void end() {
    if (!_generating) return;
    _generating = false;
    if (_model != nullptr) _bindings.generateEnd(_model);
  }

  @override
  void dispose() {
    unload();
    if (_piece != nullptr) calloc.free(_piece);
    _piece = nullptr;
  }

  Pointer<NativeLlamaModel> _requireModel() {
    if (_model == nullptr) throw const LlamaNotLoadedException();
    return _model;
  }

  String _takeString(Pointer<Utf8> text, String operation) {
    if (text == nullptr) _fail(operation);
    try {
      return text.toDartString();
    } finally {
      _bindings.freeString(text);
    }
  }

  String _lastError() {
    final error = _bindings.lastError();
    return error == nullptr ? 'unknown error' : error.toDartString();
  }

  Never _fail(String operation) {
    final message = _lastError();
    if (message == 'cancelled') throw const LlamaCancelledException();
    throw LlamaEngineException('$operation: $message');
  }
}
