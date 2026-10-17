import 'dart:collection';
import 'dart:ffi';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/ffi/bindings.dart';
import 'package:bergamot_translator/src/model_manager.dart';
import 'package:ffi/ffi.dart';

/// Synchronous access to the native engine with a small cache of loaded
/// models. Blocks the calling isolate: only used inside the translation
/// isolate (see `IsolateBergamotEngine`).
final class NativeEngine {
  new(this._bindings, {this.maxLoadedModels = 3})
    : assert(maxLoadedModels >= 2, 'A pivot needs two loaded models');

  /// Opens the library ([BergamotBindings.open]) and checks its ABI.
  factory open({String? libraryPath, int maxLoadedModels = 3}) {
    final BergamotBindings bindings;
    try {
      bindings = BergamotBindings(BergamotBindings.open(libraryPath));
    } on Object catch (error) {
      throw BergamotEngineException('Cannot load the native engine: $error');
    }
    final abi = bindings.abiVersion();
    if (abi != BergamotBindings.expectedAbiVersion) {
      throw BergamotEngineException(
        'Native engine ABI $abi, expected '
        '${BergamotBindings.expectedAbiVersion}',
      );
    }
    return NativeEngine(bindings, maxLoadedModels: maxLoadedModels);
  }

  final BergamotBindings _bindings;
  final int maxLoadedModels;

  /// Loaded models, least recently used first.
  final LinkedHashMap<String, Pointer<NativeModel>> _models = LinkedHashMap();

  /// Engine version, e.g. `bergamot v0.6.0`.
  String get version => _bindings.version().toDartString();

  /// Keys of the loaded models, least recently used first.
  List<String> get loadedModels => List.unmodifiable(_models.keys);

  String translate(List<ModelPaths> chain, String text, {bool html = false}) {
    if (chain.isEmpty || chain.length > 2) {
      throw ArgumentError.value(chain.length, 'chain', 'Must be 1 or 2');
    }
    final models = [for (final paths in chain) _load(paths, keep: chain)];
    return using((arena) {
      final input = text.toNativeUtf8(allocator: arena);
      final output = models.length == 1
          ? _bindings.translate(models.single, input, html ? 1 : 0)
          : _bindings.translatePivot(models[0], models[1], input, html ? 1 : 0);
      return _take(output, 'translate');
    });
  }

  void release(String key) {
    final model = _models.remove(key);
    if (model != null) _bindings.modelDestroy(model);
  }

  void dispose() {
    _models.values.forEach(_bindings.modelDestroy);
    _models.clear();
  }

  Pointer<NativeModel> _load(
    ModelPaths paths, {
    required List<ModelPaths> keep,
  }) {
    final cached = _models.remove(paths.key);
    if (cached != null) return _models[paths.key] = cached;
    final model = using((arena) {
      Pointer<Utf8> utf8(String? value) =>
          value == null ? nullptr : value.toNativeUtf8(allocator: arena);
      return _bindings.modelCreate(
        utf8(paths.model),
        utf8(paths.shortlist),
        utf8(paths.sourceVocab),
        utf8(paths.targetVocab),
        nullptr,
      );
    });
    if (model == nullptr) _fail('load ${paths.key}');
    _models[paths.key] = model;
    // Evict the least recently used models that this request does not use.
    final keepKeys = {for (final p in keep) p.key};
    while (_models.length > maxLoadedModels) {
      final victim = _models.keys.firstWhere(
        (key) => !keepKeys.contains(key),
        orElse: () => '',
      );
      if (victim.isEmpty) break;
      release(victim);
    }
    return model;
  }

  String _take(Pointer<Utf8> output, String operation) {
    if (output == nullptr) _fail(operation);
    try {
      return output.toDartString();
    } finally {
      _bindings.freeString(output);
    }
  }

  Never _fail(String operation) {
    final error = _bindings.lastError();
    final message = error == nullptr ? 'unknown error' : error.toDartString();
    throw BergamotEngineException('$operation: $message');
  }
}
