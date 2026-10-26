import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/on_device_ai/cubit/on_device_ai_settings_state.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/platform/model_file_picker.dart';

export 'on_device_ai_settings_state.dart';

/// The "On-device AI" settings: the catalogue's models with how they suit
/// this device ([OnDeviceFit]), downloads (with progress and [cancel]),
/// deletion, which model translates and which does the AI extras
/// ([select]) and import from files ([OnDeviceModels]).
///
/// Nothing is downloaded unless [download] is called (the user tapped
/// download); a download on a metered network with "Download over Wi-Fi
/// only" on ends with [OnDeviceModelErrorKind.metered] and [download] with
/// `overMeteredNetwork` retries it anyway. A download that is running when
/// the page opens (it outlives the page) is shown and can be cancelled.
/// [importFromFiles] never goes online. Failures never throw: they are
/// reported as an [OnDeviceModelOutcome] or [OnDeviceImportOutcome];
/// errors other than a metered network or a cancelled download also go to
/// `addError`. Without [OnDeviceModels] (the web, an unsupported device)
/// the state says it is not [OnDeviceAiSettingsState.supported].
class OnDeviceAiSettingsCubit extends Cubit<OnDeviceAiSettingsState> {
  /// [picker] (default [ModelFilePicker]) hands out the picked files: on
  /// Android documents read in place, copied straight into the models
  /// folder ([OnDeviceModels.importSources]). Files with local paths (the
  /// fallback picker's copies in the cache) are moved into place instead
  /// of copied when [movePickedFiles] (default: on Android).
  ///
  /// `engineBuild` tells which build of the engine library runs on this
  /// processor (read once on [load], for support).
  new({
    this._models,
    ModelFilePicker? picker,
    bool? movePickedFiles,
    this._engineBuild,
  }) : _picker = picker ?? ModelFilePicker(),
       _movePickedFiles = movePickedFiles ?? runsOnAndroid,
       super(const OnDeviceAiSettingsState());

  final OnDeviceModels? _models;
  final LlamaEngineBuild? Function()? _engineBuild;
  final ModelFilePicker _picker;
  final bool _movePickedFiles;
  StreamSubscription<void>? _changes;

  Future<void> load() async {
    final models = _models;
    if (models == null) {
      emit(state.copyWith(status: OnDeviceAiSettingsStatus.ready));
      return;
    }
    emit(state.copyWith(status: OnDeviceAiSettingsStatus.loading));
    try {
      await models.ready;
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    await _changes?.cancel();
    _changes = models.changes.listen((_) => unawaited(_refresh()));
    await _refresh();
    if (isClosed) return;
    emit(
      state.copyWith(
        status: OnDeviceAiSettingsStatus.ready,
        supported: true,
        engineBuild: () => _engineBuild?.call(),
      ),
    );
    // Downloads started before the page opened.
    for (final MapEntry(key: id, value: fraction) in models.downloads.entries) {
      emit(state.copyWith(progress: {...state.progress, id: fraction}));
      unawaited(download(id));
    }
  }

  /// Downloads model [id] (resuming what was downloaded before) and makes
  /// it the one in use for its role, honouring "Download over Wi-Fi only"
  /// unless [overMeteredNetwork].
  Future<void> download(String id, {bool overMeteredNetwork = false}) {
    final models = _models;
    return _run(
      id,
      OnDeviceModelOperation.download,
      () => models!.download(
        id,
        overMeteredNetwork: overMeteredNetwork,
        onProgress: (fraction) => _reportProgress(id, fraction),
      ),
    );
  }

  /// Stops the running download of [id] (what was downloaded is kept).
  void cancel(String id) {
    if (state.pending[id] != OnDeviceModelOperation.download) return;
    _models?.cancelDownload(id);
  }

  /// Deletes model [id] (or what was downloaded of it).
  Future<void> delete(String id) {
    final models = _models;
    return _run(id, OnDeviceModelOperation.delete, () => models!.delete(id));
  }

  /// Makes the installed model [id] the one in use for its role.
  Future<void> select(String id) async {
    final models = _models;
    final model = state.model(id);
    if (models == null ||
        model == null ||
        !model.installed ||
        state.inUse(id) ||
        state.pending.containsKey(id)) {
      return;
    }
    try {
      await switch (model.role) {
        LlamaModelRole.translation => models.selectTranslationModel(id),
        LlamaModelRole.assistant => models.selectAssistantModel(id),
      };
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    await _refresh();
  }

  /// Lets the user pick model files (downloaded by hand) and installs the
  /// on-device models among them, without going online. Cancelling the
  /// picker changes nothing. On Android the picked documents are copied
  /// once, straight into the models folder, after their names, sizes and
  /// the free space were checked (they are a few GB); a model that does
  /// not fit is reported ([OnDeviceImportOutcome.space]).
  Future<void> importFromFiles() async {
    final models = _models;
    if (models == null || state.importing) return;
    void start() {
      if (isClosed || state.importing) return;
      emit(state.copyWith(importing: true, importOutcome: () => null));
    }

    OnDeviceImportOutcome outcome;
    try {
      final files = await _picker.pick(onCopying: start);
      if (files.isEmpty) {
        if (!isClosed && state.importing) {
          emit(state.copyWith(importing: false));
        }
        return;
      }
      start();
      try {
        final paths = [for (final file in files) ?file.path];
        final result = paths.length == files.length
            ? await models.importFiles(paths, move: _movePickedFiles)
            : await models.importSources(files);
        outcome = OnDeviceImportOutcome(
          models: result.models,
          unmatchedFiles: result.unmatchedFiles,
          tooBig: {
            for (final id in result.installed)
              if (models.catalog.model(id) case final model?
                  when models.fitOf(model) == OnDeviceFit.tooBig)
                id,
          },
          space: result.errors.values
              .map(SpaceShortfall.of)
              .nonNulls
              .firstOrNull,
        );
      } finally {
        await _clearPickedCopies();
      }
    } on Object catch (error, stackTrace) {
      outcome = const OnDeviceImportOutcome(failed: true);
      addError(error, stackTrace);
    }
    await _refresh();
    if (isClosed) return;
    emit(state.copyWith(importing: false, importOutcome: () => outcome));
  }

  @override
  Future<void> close() async {
    await _changes?.cancel();
    await super.close();
  }

  Future<void> _run(
    String id,
    OnDeviceModelOperation operation,
    Future<void> Function() action,
  ) async {
    if (_models == null ||
        state.model(id) == null ||
        state.pending.containsKey(id)) {
      return;
    }
    emit(
      state.copyWith(
        pending: {...state.pending, id: operation},
        outcome: () => null,
      ),
    );
    final failure = await _attempt(action);
    await _refresh();
    if (isClosed) return;
    emit(
      state.copyWith(
        pending: {...state.pending}..remove(id),
        progress: {...state.progress}..remove(id),
        outcome: () => OnDeviceModelOutcome(
          model: id,
          operation: operation,
          succeeded: failure == null,
          error: failure,
        ),
      ),
    );
  }

  /// Runs [action]; why it failed, or null. Errors other than a metered
  /// network or a cancelled download go to `addError`. (A helper, not a
  /// local assigned in a `catch` and read by a closure: dart2js gets that
  /// wrong.)
  Future<OnDeviceModelError?> _attempt(Future<void> Function() action) async {
    try {
      await action();
      return null;
    } on Object catch (error, stackTrace) {
      final failure = OnDeviceModelError.of(error);
      if (failure.kind != OnDeviceModelErrorKind.metered &&
          failure.kind != OnDeviceModelErrorKind.cancelled) {
        addError(error, stackTrace);
      }
      return failure;
    }
  }

  /// Reads the models and the choices again.
  Future<void> _refresh() async {
    final models = _models;
    if (models == null || isClosed) return;
    List<OnDeviceModel> listed;
    try {
      listed = await models.models();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      listed = state.models;
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        models: listed,
        translationModel: () => models.translationModel,
        assistantModel: () => models.assistantModel,
      ),
    );
  }

  /// Emits download progress in whole percent steps only.
  void _reportProgress(String id, double fraction) {
    if (isClosed || !state.pending.containsKey(id)) return;
    final previous = state.progress[id];
    if (previous != null &&
        (previous * 100).floor() == (fraction * 100).floor()) {
      return;
    }
    emit(state.copyWith(progress: {...state.progress, id: fraction}));
  }

  /// The picker's copies are only needed during the import.
  Future<void> _clearPickedCopies() async {
    try {
      await _picker.clearCopies();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
  }
}
