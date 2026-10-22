import 'dart:async';
import 'dart:io' show File;

import 'package:equatable/equatable.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart'
    show OfflineModelsCubit;
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/settings/models/model_source.dart';

/// How a model suits this device's memory ([OnDeviceModels.fitOf]).
enum OnDeviceFit {
  /// At least [LlamaCatalogModel.recommendedRamMb] of RAM: "Fits this
  /// phone".
  ok,

  /// At least [LlamaCatalogModel.minRamMb] but less than recommended:
  /// "May be slow on this phone".
  slow,

  /// Less than [LlamaCatalogModel.minRamMb], or a low-RAM device: "Needs
  /// more memory". Not offered for download; importing stays possible.
  tooBig,

  /// The device's memory is not known (no answer from Android).
  unknown,
}

/// A "Download over Wi-Fi only" download on a metered network: nothing was
/// downloaded (the settings ask whether to download anyway).
final class OnDeviceModelMeteredException implements Exception {
  const new();

  @override
  String toString() => 'OnDeviceModelMeteredException()';
}

/// A download of a model this device has too little memory for
/// ([OnDeviceFit.tooBig]): nothing was downloaded.
final class OnDeviceModelTooBigException implements Exception {
  const new(this.model);

  /// The model id.
  final String model;

  @override
  String toString() => 'OnDeviceModelTooBigException($model)';
}

/// A catalogue model with its state on this device.
class OnDeviceModel extends Equatable {
  const new({
    required this.model,
    required this.fit,
    this.installed = false,
    this.partialBytes = 0,
  });

  final LlamaCatalogModel model;

  /// How it suits this device's memory.
  final OnDeviceFit fit;

  /// Whether exactly this file is installed.
  final bool installed;

  /// Bytes of an interrupted download, which the next download resumes
  /// (0 when none or [installed]).
  final int partialBytes;

  /// [LlamaCatalogModel.id].
  String get id => model.id;

  /// [LlamaCatalogModel.role].
  LlamaModelRole get role => model.role;

  @override
  List<Object?> get props => [model, fit, installed, partialBytes];
}

/// The result of [OnDeviceModels.importFiles].
class OnDeviceImportResult extends Equatable {
  const new({
    this.models = const {},
    this.unmatchedFiles = 0,
    this.errors = const {},
  });

  /// What happened per model id that an imported file belongs to, in
  /// catalogue order.
  final Map<String, LlamaImportStatus> models;

  /// Imported files that are no model of the catalogue.
  final int unmatchedFiles;

  /// Why installing failed, by model id ([LlamaImportStatus.failed]).
  final Map<String, Object> errors;

  /// The ids of the models this import installed.
  List<String> get installed => [
    for (final MapEntry(:key, :value) in models.entries)
      if (value == LlamaImportStatus.installed) key,
  ];

  @override
  List<Object?> get props => [models, unmatchedFiles, errors];
}

/// The app's on-device AI models: the bundled [catalog], which of them are
/// installed ([LlamaModelManager]), how they suit this device's memory
/// ([fitOf]), the app's download rules and which model translates
/// ([translationModel]) and which does the AI extras ([assistantModel]).
///
/// * Downloads only happen when [download] is called (the user tapped
///   download), from the model source of the settings ([ModelSource]: the
///   publisher, Hugging Face, or a mirror), and follow the "Download over
///   Wi-Fi only" setting of the offline languages
///   ([OfflineModelsCubit.wifiOnlyKey], default on): on a metered network
///   they throw [OnDeviceModelMeteredException] unless
///   `overMeteredNetwork`. A model this device lacks the memory for
///   ([OnDeviceFit.tooBig]) is not downloaded; [importFiles] still
///   installs it (the user was warned).
/// * Every file is checked against the catalogue's size and SHA-256 before
///   it is installed (by the manager).
/// * The chosen models are stored under [translationModelKey] and
///   [assistantModelKey]; without a choice (or when the chosen model is
///   not installed) the first installed model of the role in catalogue
///   order is used. A download or import makes its model the chosen one.
/// * [changes] fires after every install, deletion and choice, so the
///   runtime can update its providers and unload a deleted model.
class OnDeviceModels {
  /// Reads the installed models and the choices in the background
  /// ([ready]); until then [translationModel] and [assistantModel] are
  /// null.
  new({
    required this.catalog,
    required this.manager,
    required this._store,
    this._memory,
    Future<bool> Function()? isMeteredConnection,
    ModelSource Function()? modelSource,
  }) : _isMetered = isMeteredConnection ?? _neverMetered,
       _modelSource = modelSource ?? _currentModelSource {
    ready = _refresh(notify: true, readChoices: true);
  }

  /// [KeyValueStore] key of the chosen translation model's id.
  static const translationModelKey = 'onDeviceAi.translationModel';

  /// [KeyValueStore] key of the chosen assistant model's id.
  static const assistantModelKey = 'onDeviceAi.assistantModel';

  /// The downloadable models (`packages/llama_engine/assets/models.json`).
  final LlamaModelCatalog catalog;

  /// Downloads, imports and deletes the files.
  final LlamaModelManager manager;

  final KeyValueStore _store;
  final DeviceMemory? _memory;
  final Future<bool> Function() _isMetered;
  final ModelSource Function() _modelSource;
  final _changes = StreamController<void>.broadcast();
  final Map<String, _Download> _downloads = {};

  Set<String> _installed = const {};
  String? _chosenTranslation;
  String? _chosenAssistant;

  /// Completes once the installed models and the choices are read.
  late final Future<void> ready;

  static Future<bool> _neverMetered() async => false;

  static ModelSource _currentModelSource() => ModelSource.current;

  /// Fires after a model was installed, deleted or chosen.
  Stream<void> get changes => _changes.stream;

  /// The id of the installed model that translates: the chosen one, else
  /// the first installed translation model; null without one.
  String? get translationModel =>
      _selected(LlamaModelRole.translation, _chosenTranslation);

  /// The id of the installed model that does the AI extras (refine,
  /// explain, dictionary, proofread…): the chosen one, else the first
  /// installed assistant model; null without one.
  String? get assistantModel =>
      _selected(LlamaModelRole.assistant, _chosenAssistant);

  /// The running downloads: the fraction done (0 to 1) by model id.
  Map<String, double> get downloads => {
    for (final MapEntry(:key, :value) in _downloads.entries)
      key: value.fraction,
  };

  /// Every catalogue model with its state here, in catalogue order (reads
  /// the installed models again).
  Future<List<OnDeviceModel>> models() async {
    await _refresh(notify: false);
    return [
      for (final model in catalog.models)
        OnDeviceModel(
          model: model,
          fit: fitOf(model),
          installed: _installed.contains(model.id),
          partialBytes: _installed.contains(model.id)
              ? 0
              : await _partialBytes(model),
        ),
    ];
  }

  /// The `.gguf` file of the installed model [id] (the exact catalogue
  /// file); null when it is not installed.
  Future<String?> pathOf(String id) async {
    final model = catalog.model(id);
    if (model == null) return null;
    final installed = await manager.installedModel(id);
    return installed != null && installed.matches(model)
        ? installed.path
        : null;
  }

  /// How [model] suits this device's memory: RAM (`totalMem`, in MiB)
  /// against [LlamaCatalogModel.minRamMb] and
  /// [LlamaCatalogModel.recommendedRamMb]. A low-RAM device (Android Go)
  /// fits none.
  OnDeviceFit fitOf(LlamaCatalogModel model) {
    final memory = _memory;
    if (memory == null) return OnDeviceFit.unknown;
    if (memory.isLowRam) return OnDeviceFit.tooBig;
    final total = memory.totalBytes;
    if (total == null) return OnDeviceFit.unknown;
    final megabytes = total ~/ (1024 * 1024);
    if (megabytes < model.minRamMb) return OnDeviceFit.tooBig;
    if (megabytes < model.recommendedRamMb) return OnDeviceFit.slow;
    return OnDeviceFit.ok;
  }

  /// Whether downloads on a metered network ask first (the offline
  /// languages' setting).
  Future<bool> wifiOnly() async {
    try {
      return await _store.read(OfflineModelsCubit.wifiOnlyKey) != 'false';
    } on Object {
      return true;
    }
  }

  /// Downloads model [id] (resuming an interrupted download) and makes it
  /// the chosen model of its role. [onProgress] receives the fraction done
  /// (0 to 1). A download of [id] that is running already is joined (no
  /// second check, the same result).
  ///
  /// Throws [ArgumentError] for an unknown id,
  /// [OnDeviceModelTooBigException] for a model this device lacks the
  /// memory for, [OnDeviceModelMeteredException] on a metered network when
  /// [wifiOnly] (unless [overMeteredNetwork]), and the
  /// [LlamaModelInstallException]s of the download
  /// ([LlamaDownloadCancelledException] after [cancelDownload]).
  Future<void> download(
    String id, {
    bool overMeteredNetwork = false,
    void Function(double fraction)? onProgress,
  }) async {
    final model = catalog.model(id);
    if (model == null) throw ArgumentError.value(id, 'id', 'Unknown model');
    if (_downloads[id] case final running?) {
      if (onProgress != null) running.listeners.add(onProgress);
      return await running.future;
    }
    if (fitOf(model) == OnDeviceFit.tooBig) {
      throw OnDeviceModelTooBigException(id);
    }
    if (!overMeteredNetwork && await wifiOnly() && await _isMetered()) {
      throw const OnDeviceModelMeteredException();
    }
    final download = _Download(model.size)..listeners.addAll([?onProgress]);
    download.future = _download(model, download);
    _downloads[id] = download;
    try {
      await download.future;
    } finally {
      if (identical(_downloads[id], download)) _downloads.remove(id);
    }
  }

  Future<void> _download(LlamaCatalogModel model, _Download download) async {
    final source = _modelSource();
    manager
      ..mirror = source.mirror()
      ..fallbackToDefault = source.fallsBackToDefault;
    await manager.install(
      model,
      onProgress: (progress) => download.report(progress.receivedBytes),
    );
    await _choose(model);
    await _refresh(notify: true);
  }

  /// Stops the running download of [id]: it ends with a
  /// [LlamaDownloadCancelledException] and the next [download] resumes it.
  void cancelDownload(String id) => manager.cancel(id);

  /// Installs the models among the files at [paths] (picked by the user);
  /// never goes online. Models this device lacks the memory for are
  /// installed too. The last model installed of each role becomes the
  /// chosen one, unless not [choose] (models received from another phone).
  /// With [move], verified files are moved instead of copied (for
  /// temporary copies, such as the file picker's).
  Future<OnDeviceImportResult> importFiles(
    List<String> paths, {
    bool move = false,
    bool choose = true,
  }) async {
    final result = await manager.importFiles(
      [for (final path in paths) File(path)],
      catalog: catalog,
      move: move,
    );
    for (final role in choose ? LlamaModelRole.values : <LlamaModelRole>[]) {
      final last = result.installed.where((model) => model.role == role);
      if (last.lastOrNull case final model?) await _choose(model);
    }
    await _refresh(notify: result.installed.isNotEmpty);
    return OnDeviceImportResult(
      models: {
        for (final outcome in result.models) outcome.model.id: outcome.status,
      },
      unmatchedFiles: result.unmatched.length,
      errors: {
        for (final outcome in result.models) outcome.model.id: ?outcome.error,
      },
    );
  }

  /// Deletes model [id] (and a partial download of it); the choice falls
  /// back to another installed model of the role.
  Future<void> delete(String id) async {
    await manager.delete(id);
    await _refresh(notify: true);
  }

  /// Deletes every model and partial download and forgets the choices
  /// ("Delete all local data"). Every step is attempted; the first error
  /// is rethrown.
  Future<void> deleteAll() async {
    Object? failure;
    StackTrace? failureTrace;
    Future<void> attempt(Future<void> Function() step) async {
      try {
        await step();
      } on Object catch (error, stackTrace) {
        failure ??= error;
        failureTrace ??= stackTrace;
      }
    }

    await attempt(manager.deleteAll);
    await attempt(() => _store.delete(translationModelKey));
    await attempt(() => _store.delete(assistantModelKey));
    _chosenTranslation = null;
    _chosenAssistant = null;
    await attempt(() => _refresh(notify: true));
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureTrace ?? StackTrace.current);
    }
  }

  /// Makes the translation model [id] the one that translates; null goes
  /// back to the default (the first installed one). Throws [ArgumentError]
  /// for an id that is no translation model of the catalogue.
  Future<void> selectTranslationModel(String? id) =>
      _select(LlamaModelRole.translation, id);

  /// Makes the assistant model [id] the one that does the AI extras; null
  /// goes back to the default (the first installed one). Throws
  /// [ArgumentError] for an id that is no assistant model of the
  /// catalogue.
  Future<void> selectAssistantModel(String? id) =>
      _select(LlamaModelRole.assistant, id);

  /// Closes [changes] and the manager's own HTTP client.
  Future<void> dispose() async {
    manager.close();
    await _changes.close();
  }

  Future<void> _select(LlamaModelRole role, String? id) async {
    if (id != null && catalog.model(id)?.role != role) {
      throw ArgumentError.value(id, 'id', 'Not a ${role.name} model');
    }
    final key = _keyOf(role);
    if (id == null) {
      await _store.delete(key);
    } else {
      await _store.write(key, id);
    }
    _remember(role, id);
    _notify();
  }

  Future<void> _choose(LlamaCatalogModel model) async {
    try {
      await _store.write(_keyOf(model.role), model.id);
    } on Object {
      // The choice is kept for this run.
    }
    _remember(model.role, model.id);
  }

  void _remember(LlamaModelRole role, String? id) => switch (role) {
    LlamaModelRole.translation => _chosenTranslation = id,
    LlamaModelRole.assistant => _chosenAssistant = id,
  };

  static String _keyOf(LlamaModelRole role) => switch (role) {
    LlamaModelRole.translation => translationModelKey,
    LlamaModelRole.assistant => assistantModelKey,
  };

  String? _selected(LlamaModelRole role, String? chosen) {
    final models = catalog.ofRole(role);
    if (chosen != null &&
        _installed.contains(chosen) &&
        models.any((model) => model.id == chosen)) {
      return chosen;
    }
    for (final model in models) {
      if (_installed.contains(model.id)) return model.id;
    }
    return null;
  }

  /// Reads the installed models (the exact catalogue files) and, with
  /// [readChoices], the stored choices (afterwards the ones in memory are
  /// written through); notifies [changes] when [notify] or anything
  /// differs.
  Future<void> _refresh({
    required bool notify,
    bool readChoices = false,
  }) async {
    final before = (translationModel, assistantModel, _installed);
    try {
      final installed = await manager.installed();
      _installed = {
        for (final model in catalog.models)
          if (installed.any((entry) => entry.matches(model))) model.id,
      };
    } on Object {
      // Kept as it was: the folder could not be read.
    }
    if (readChoices) {
      _chosenTranslation = await _read(translationModelKey);
      _chosenAssistant = await _read(assistantModelKey);
    }
    final after = (translationModel, assistantModel, _installed);
    if (notify ||
        before.$1 != after.$1 ||
        before.$2 != after.$2 ||
        !_sameSet(before.$3, after.$3)) {
      _notify();
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<String?> _read(String key) async {
    try {
      return await _store.read(key);
    } on Object {
      return null;
    }
  }

  Future<int> _partialBytes(LlamaCatalogModel model) async {
    try {
      return await manager.partialBytes(model);
    } on Object {
      return 0;
    }
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// A running [OnDeviceModels.download] that later calls can join.
class _Download {
  new(this.size);

  final int size;
  final List<void Function(double fraction)> listeners = [];
  late final Future<void> future;
  double fraction = 0;

  void report(int received) {
    fraction = size == 0 ? 1 : received / size;
    for (final listener in [...listeners]) {
      listener(fraction);
    }
  }
}
