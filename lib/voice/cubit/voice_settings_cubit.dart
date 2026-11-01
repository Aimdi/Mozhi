import 'package:bloc/bloc.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/platform/model_file_picker.dart';
import 'package:mozhi/voice/cubit/voice_settings_state.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/speech_input_service.dart';

export 'voice_settings_state.dart';

/// The "Voice input" settings: which recogniser voice input uses
/// ([SpeechInputService.engine]) and the offline speech models
/// ([OfflineSpeech]: download, delete, the model in use, import from
/// files), with the voice activity model that comes with them
/// ([VoiceSettingsState.voiceDetection], [downloadVoiceDetection] for
/// speech models installed before it).
///
/// Nothing is downloaded unless [download] is called (the user tapped
/// download); a download on a metered network with "Download over Wi-Fi
/// only" on ends with [VoiceModelErrorKind.metered] and [download] with
/// `overMeteredNetwork` retries it anyway. [importFromFiles] never goes
/// online. Models the device has too little memory for are not listed
/// unless installed ([voiceModelFitsMemory]). After every change of the
/// models, the [SpeechInputService] is told
/// ([SpeechInputService.offlineModelsChanged]). Failures never throw:
/// they are reported as a [VoiceModelOutcome] or [VoiceImportOutcome];
/// errors other than a metered network also go to `addError`.
class VoiceSettingsCubit extends Cubit<VoiceSettingsState> {
  /// [picker] (default [ModelFilePicker]) hands out the picked files: on
  /// Android documents read in place and copied straight into the models
  /// folder ([OfflineSpeech.importSources]), with no copy in the cache.
  new({required this._speechInput, this._offline, ModelFilePicker? picker})
    : _picker = picker ?? ModelFilePicker(),
      super(const VoiceSettingsState());

  final SpeechInputService _speechInput;
  final OfflineSpeech? _offline;
  final ModelFilePicker _picker;

  Future<void> load() async {
    emit(state.copyWith(status: VoiceSettingsStatus.loading));
    await _speechInput.loadSettings();
    final offline = _offline;
    final supported =
        offline != null &&
        offline.isAvailable &&
        _speechInput.isOfflineSupported;
    final vad = supported ? offline.vadModel : null;
    final (installed, selected) = supported
        ? await _readInstalled(offline)
        : (const <String>{}, null);
    final models = supported
        ? _listed(offline, installed)
        : const <VoiceModel>[];
    final vadInstalled = vad != null && await offline!.isVadReady();
    if (isClosed) return;
    emit(
      state.copyWith(
        status: VoiceSettingsStatus.ready,
        engine: _speechInput.engine.value,
        offlineSupported: supported,
        models: models,
        installed: installed,
        selected: () => selected,
        voiceDetection: () => vad == null
            ? null
            : VoiceModel(id: vad.id, sizeBytes: vad.size, url: vad.url),
        voiceDetectionInstalled: vadInstalled,
        engineBuild: () => supported ? offline.engineBuild : null,
      ),
    );
  }

  /// Chooses the recogniser of the next voice input session.
  Future<void> setEngine(VoiceInputEngine engine) async {
    emit(state.copyWith(engine: engine));
    try {
      await _speechInput.setEngine(engine);
    } on Object catch (error, stackTrace) {
      // Kept for this session: the service already uses it.
      addError(error, stackTrace);
    }
  }

  /// Downloads model [id] and makes it the one in use, honouring
  /// "Download over Wi-Fi only" unless [overMeteredNetwork].
  Future<void> download(String id, {bool overMeteredNetwork = false}) {
    final offline = _offline;
    return _run(
      id,
      VoiceModelOperation.download,
      () => offline!.download(
        id,
        overMeteredNetwork: overMeteredNetwork,
        onProgress: (fraction) => _reportProgress(id, fraction),
      ),
    );
  }

  /// Downloads the voice activity model alone (speech models installed
  /// before the app had it), honouring "Download over Wi-Fi only" unless
  /// [overMeteredNetwork]. Reported like [download] under its id.
  Future<void> downloadVoiceDetection({bool overMeteredNetwork = false}) {
    final offline = _offline;
    final id = state.voiceDetection?.id;
    if (id == null) return Future.value();
    return _run(
      id,
      VoiceModelOperation.download,
      () => offline!.downloadVoiceDetection(
        overMeteredNetwork: overMeteredNetwork,
        onProgress: (fraction) => _reportProgress(id, fraction),
      ),
    );
  }

  /// Stops the running download of model [id] (or of the voice activity
  /// model, under its id) that this cubit started: it ends without an
  /// outcome (nothing to explain) and nothing is installed; the bytes
  /// received so far are kept, so downloading it again resumes. Does
  /// nothing when it is not downloading.
  void cancel(String id) {
    if (state.pending[id] != VoiceModelOperation.download) return;
    _offline?.cancelDownload(id);
  }

  /// Deletes model [id].
  Future<void> delete(String id) {
    final offline = _offline;
    return _run(id, VoiceModelOperation.delete, () => offline!.delete(id));
  }

  /// Makes the installed model [id] the one in use.
  Future<void> select(String id) async {
    final offline = _offline;
    if (offline == null || !state.isInstalled(id) || state.selected == id) {
      return;
    }
    emit(state.copyWith(selected: () => id));
    try {
      await offline.select(id);
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    await _refresh();
  }

  /// Lets the user pick model files (downloaded by hand) and installs the
  /// Whisper models among them, without going online. Cancelling the
  /// picker changes nothing.
  Future<void> importFromFiles() async {
    final offline = _offline;
    if (offline == null || !state.offlineSupported || state.importing) {
      return;
    }
    void start() {
      if (isClosed || state.importing) return;
      emit(state.copyWith(importing: true, importOutcome: () => null));
    }

    VoiceImportOutcome outcome;
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
            ? await offline.importFiles(paths)
            : await offline.importSources(files);
        final vadId = state.voiceDetection?.id;
        final speech = result.models.where((entry) => entry.model.id != vadId);
        outcome = VoiceImportOutcome(
          // The voice activity model is only reported on its own.
          models: {
            for (final entry in speech.isEmpty ? result.models : speech)
              entry.model.id: entry.status,
          },
          unmatchedFiles: result.unmatched.length,
          space: [
            for (final entry in result.models) SpaceShortfall.of(entry.error),
          ].nonNulls.firstOrNull,
        );
      } finally {
        await _clearPickedCopies();
      }
    } on Object catch (error, stackTrace) {
      outcome = const VoiceImportOutcome(failed: true);
      addError(error, stackTrace);
    }
    await _refresh();
    if (isClosed) return;
    emit(state.copyWith(importing: false, importOutcome: () => outcome));
  }

  Future<void> _run(
    String id,
    VoiceModelOperation operation,
    Future<void> Function() action,
  ) async {
    if (_offline == null ||
        (state.model(id) == null && id != state.voiceDetection?.id) ||
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
    final cancelled = failure?.kind == VoiceModelErrorKind.cancelled;
    emit(
      state.copyWith(
        pending: {...state.pending}..remove(id),
        progress: {...state.progress}..remove(id),
        // The user stopped it: nothing to tell.
        outcome: () => cancelled
            ? null
            : VoiceModelOutcome(
                model: id,
                operation: operation,
                succeeded: failure == null,
                error: failure,
              ),
      ),
    );
  }

  /// Runs [action]; why it failed, or null. Errors other than a metered
  /// network go to `addError`. (A helper, not a local assigned in a
  /// `catch` and read by a closure: dart2js gets that wrong.)
  Future<VoiceModelError?> _attempt(Future<void> Function() action) async {
    try {
      await action();
      return null;
    } on Object catch (error, stackTrace) {
      final failure = VoiceModelError.of(error);
      if (failure.kind != VoiceModelErrorKind.metered &&
          failure.kind != VoiceModelErrorKind.cancelled) {
        addError(error, stackTrace);
      }
      return failure;
    }
  }

  /// Reads the installed models again and tells the voice input service.
  Future<void> _refresh() async {
    final offline = _offline;
    if (offline == null) return;
    final (installed, selected) = await _readInstalled(offline);
    final vadInstalled =
        state.voiceDetection != null && await offline.isVadReady();
    try {
      await _speechInput.offlineModelsChanged();
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        models: _listed(offline, installed),
        installed: installed,
        selected: () => selected,
        voiceDetectionInstalled: vadInstalled,
      ),
    );
  }

  /// The speech models to list: those that fit the device's memory, and
  /// the [installed] ones (to use or delete them), fastest first.
  static List<VoiceModel> _listed(
    OfflineSpeech offline,
    Set<String> installed,
  ) {
    final memory = offline.memory;
    return [
      for (final model in offline.models)
        if (installed.contains(model.id) || voiceModelFitsMemory(model, memory))
          VoiceModel(id: model.id, sizeBytes: model.size, url: model.url),
    ];
  }

  Future<(Set<String>, String?)> _readInstalled(OfflineSpeech offline) async {
    try {
      return (await offline.installed(), await offline.selected());
    } on Object catch (error, stackTrace) {
      addError(error, stackTrace);
      return (state.installed, state.selected);
    }
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
