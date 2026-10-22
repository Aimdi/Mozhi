import 'dart:collection';
import 'dart:ffi';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/ffi/bindings.dart';
import 'package:bergamot_translator/src/engine/translation_json.dart';
import 'package:bergamot_translator/src/model_manager.dart';
import 'package:ffi/ffi.dart';
import 'package:translation_repository/translation_repository.dart';

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

  /// Keys of the chain of the most recent request ([trim] keeps them).
  List<String> _recent = const [];

  /// Engine version, e.g. `bergamot v0.6.0`.
  String get version => _bindings.version().toDartString();

  /// Keys of the loaded models, least recently used first.
  List<String> get loadedModels => List.unmodifiable(_models.keys);

  String translate(List<ModelPaths> chain, String text, {bool html = false}) {
    final models = _loadChain(chain);
    return using((arena) {
      final input = text.toNativeUtf8(allocator: arena);
      final output = models.length == 1
          ? _bindings.translate(models.single, input, html ? 1 : 0)
          : _bindings.translatePivot(models[0], models[1], input, html ? 1 : 0);
      return _take(output, 'translate');
    });
  }

  /// Translates [texts] through [chain] in one native call
  /// (`mozhi_bergamot_translate_ex`); with [details] with sentences, word
  /// alignment and quality scores.
  List<OfflineTranslation> translateBatch(
    List<ModelPaths> chain,
    List<String> texts, {
    bool html = false,
    bool details = false,
  }) {
    final models = _loadChain(chain);
    if (texts.isEmpty) return const [];
    final flags =
        (html ? BergamotBindings.translateHtml : 0) |
        (details
            ? BergamotBindings.translateAlignment |
                  BergamotBindings.translateQuality
            : 0);
    final json = using((arena) {
      final array = arena<Pointer<Utf8>>(texts.length);
      for (var i = 0; i < texts.length; i++) {
        array[i] = texts[i].toNativeUtf8(allocator: arena);
      }
      final output = _bindings.translateEx(
        models.first,
        models.length == 2 ? models[1] : nullptr,
        array,
        texts.length,
        flags,
      );
      return _take(output, 'translate');
    });
    return parseBergamotTranslations(json, count: texts.length);
  }

  /// Loads the models of [chain] without translating.
  void preload(List<ModelPaths> chain) => _loadChain(chain);

  /// Unloads every model but those of the most recent request.
  void trim() {
    for (final key in [..._models.keys]) {
      if (!_recent.contains(key)) release(key);
    }
  }

  void release(String key) {
    final model = _models.remove(key);
    if (model != null) _bindings.modelDestroy(model);
  }

  void dispose() {
    _models.values.forEach(_bindings.modelDestroy);
    _models.clear();
  }

  /// The loaded models of [chain] (one, or two for a pivot); it becomes the
  /// most recent chain.
  List<Pointer<NativeModel>> _loadChain(List<ModelPaths> chain) {
    if (chain.isEmpty || chain.length > 2) {
      throw ArgumentError.value(chain.length, 'chain', 'Must be 1 or 2');
    }
    final models = [for (final paths in chain) _load(paths, keep: chain)];
    _recent = [for (final paths in chain) paths.key];
    return models;
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
