import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart'
    show OfflineModelsCubit;
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// A "Download over Wi-Fi only" download on a metered network: nothing was
/// downloaded (the settings ask whether to download anyway).
final class VoiceModelMeteredException implements Exception {
  const new();

  @override
  String toString() => 'VoiceModelMeteredException()';
}

/// The app's offline speech recognition: Whisper ([WhisperSpeech]) with
/// the model the user chose and the app's download rules, and the voice
/// activity detector (Silero VAD, [WhisperSpeech.vadModel]) that tells
/// speech from silence while recording ([detectSpeech]).
///
/// * Downloads only happen when [download] or [downloadVoiceDetection] is
///   called (the user tapped download), from Hugging Face
///   ([WhisperCatalogModel.url]), and follow the "Download over Wi-Fi only"
///   setting of the offline languages ([OfflineModelsCubit.wifiOnlyKey],
///   default on): on a metered network they throw
///   [VoiceModelMeteredException] unless `overMeteredNetwork`. The voice
///   activity model (0.9 MB) comes with every speech model download.
/// * [importFiles] installs model files copied to the device by hand,
///   without any network request (for Offline only users).
/// * The model in use ([selected]) is stored under [modelKey]; without a
///   choice (or when it was deleted) the most accurate installed model is
///   used.
/// * The larger models are only offered where they fit ([fits], the
///   device's [memory]); an installed one is always listed.
class OfflineSpeech {
  /// [engineBuild] tells which build of the engine library runs on this
  /// processor ([WhisperEngineBuild], for support; null: not known).
  new({
    required this.whisper,
    required this._store,
    Future<bool> Function()? isMeteredConnection,
    ModelSource Function()? modelSource,
    this.memory,
    this._engineBuild,
  }) : _isMetered = isMeteredConnection ?? _neverMetered,
       _modelSource = modelSource ?? _currentModelSource;

  final WhisperEngineBuild Function()? _engineBuild;

  /// Which build of the engine library runs on this processor (shown in
  /// the voice input settings for support); null when not known.
  WhisperEngineBuild? get engineBuild {
    try {
      return _engineBuild?.call();
    } on Object {
      return null;
    }
  }

  /// [KeyValueStore] key of the model in use ([WhisperCatalogModel.id]).
  static const modelKey = 'voice.offlineModel';

  final WhisperSpeech whisper;
  final KeyValueStore _store;
  final Future<bool> Function() _isMetered;

  static Future<bool> _neverMetered() async => false;

  /// Where downloads come from (default [ModelSource.current], the
  /// settings'; SHARED W3-B).
  final ModelSource Function() _modelSource;

  static ModelSource _currentModelSource() => ModelSource.current;

  /// Whether Whisper runs on this device.
  bool get isAvailable => whisper.isAvailable;

  /// The downloadable models, fastest first.
  List<WhisperCatalogModel> get models => whisper.catalog.models;

  /// What Android says about the device's memory; null when unknown.
  final DeviceMemory? memory;

  /// Whether [model] suits this device's memory
  /// ([voiceModelFitsMemory]).
  bool fits(WhisperCatalogModel model) => voiceModelFitsMemory(model, memory);

  /// The catalog model [id], if listed.
  WhisperCatalogModel? model(String id) => whisper.catalog.model(id);

  /// Ids of the installed models.
  Future<Set<String>> installed() async => {
    for (final model in await whisper.installedModels()) model.id,
  };

  /// Whether a model is installed and Whisper runs here.
  Future<bool> isReady() => whisper.isReady();

  /// The id of the model transcriptions use: the chosen one when it is
  /// installed, else the most accurate installed one; null without any.
  Future<String?> selected() async =>
      (await whisper.modelFor(preferred: await _storedModel()))?.id;

  /// Chooses the model transcriptions use.
  Future<void> select(String id) => _store.write(modelKey, id);

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
  /// the one in use; the voice activity model ([vadModel]) first, when it
  /// is not installed yet. [onProgress] receives the fraction done of both
  /// (0 to 1).
  ///
  /// Throws [WhisperInsufficientSpaceException] when it does not fit in
  /// the free space (checked first), [VoiceModelMeteredException] on a
  /// metered network when [wifiOnly] (unless [overMeteredNetwork]),
  /// [ArgumentError] for an unknown id, and the
  /// [WhisperModelInstallException]s of the download
  /// ([WhisperDownloadCancelledException] after [cancelDownload]).
  Future<void> download(
    String id, {
    bool overMeteredNetwork = false,
    void Function(double fraction)? onProgress,
  }) => _cancellable(
    id,
    (abort) => _download(
      id,
      overMeteredNetwork: overMeteredNetwork,
      onProgress: onProgress,
      abort: abort,
    ),
  );

  /// Stops the running [download] of model [id] (or
  /// [downloadVoiceDetection], under the [vadModel]'s id): it fails with a
  /// [WhisperDownloadCancelledException], nothing is installed, and the
  /// bytes received so far are kept, so the next download resumes. Does
  /// nothing when none runs.
  void cancelDownload(String id) {
    final abort = _aborts[id];
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  /// The abort triggers of the running downloads, by model id.
  final Map<String, Completer<void>> _aborts = {};

  Future<void> _cancellable(
    String id,
    Future<void> Function(Future<void> abort) run,
  ) async {
    final abort = _aborts[id] = Completer<void>();
    try {
      await run(abort.future);
    } finally {
      if (identical(_aborts[id], abort)) _aborts.remove(id);
    }
  }

  Future<void> _download(
    String id, {
    required bool overMeteredNetwork,
    required void Function(double fraction)? onProgress,
    required Future<void> abort,
  }) async {
    final model = whisper.catalog.model(id);
    if (model == null) throw ArgumentError.value(id, 'id', 'Unknown model');
    // Before asking about mobile data: a download that cannot fit fails at
    // once (WhisperInsufficientSpaceException).
    await whisper.models.checkSpace(model);
    if (!overMeteredNetwork && await wifiOnly() && await _isMetered()) {
      throw const VoiceModelMeteredException();
    }
    final vad = await _vadToInstall();
    final total = model.size + (vad?.size ?? 0);
    void report(int done) => onProgress?.call(total == 0 ? 1 : done / total);
    if (vad != null) {
      await _install(vad, report, abort);
    }
    final before = vad?.size ?? 0;
    await _install(model, (received) => report(before + received), abort);
    await select(id);
  }

  /// The voice activity detection model of the catalog, if any.
  WhisperCatalogModel? get vadModel => whisper.vadModel;

  /// Whether the voice activity model is installed and runs here, so
  /// recordings are cut at real pauses ([detectSpeech]).
  Future<bool> isVadReady() async {
    try {
      return await whisper.isVadReady();
    } on Object {
      return false;
    }
  }

  /// Downloads the voice activity model alone (for speech models installed
  /// before it came with them), under the same rules as [download].
  /// Does nothing when it is installed or the catalog has none.
  Future<void> downloadVoiceDetection({
    bool overMeteredNetwork = false,
    void Function(double fraction)? onProgress,
  }) async {
    final vad = await _vadToInstall();
    if (vad == null) return;
    if (!overMeteredNetwork && await wifiOnly() && await _isMetered()) {
      throw const VoiceModelMeteredException();
    }
    await _cancellable(
      vad.id,
      (abort) => _install(
        vad,
        (received) => onProgress?.call(vad.size == 0 ? 1 : received / vad.size),
        abort,
      ),
    );
  }

  /// Every Whisper download goes through here (speech and voice activity
  /// models): [onProgress] receives the bytes received.
  Future<void> _install(
    WhisperCatalogModel model,
    void Function(int received) onProgress,
    Future<void> abort,
  ) async {
    final source = _modelSource();
    whisper.models
      ..mirror = source.mirror()
      ..fallbackToDefault = source.fallsBackToDefault;
    await whisper.download(
      model,
      onProgress: (progress) => onProgress(progress.receivedBytes),
      abort: abort,
    );
  }

  /// The voice activity model when it is listed and not installed yet.
  Future<WhisperCatalogModel?> _vadToInstall() async {
    final vad = whisper.vadModel;
    if (vad == null || await whisper.installedVad() != null) return null;
    return vad;
  }

  /// Speech probabilities of the 32 ms windows [samples] (16 kHz mono)
  /// complete in the recording ([WhisperSpeech.detectSpeech]); call
  /// [resetSpeechDetection] before each recording.
  Future<WhisperVadFrames> detectSpeech(Float32List samples) =>
      whisper.detectSpeech(samples);

  /// Starts a new recording for [detectSpeech].
  Future<void> resetSpeechDetection() => whisper.resetSpeechDetection();

  /// Deletes model [id] (and a partial download of it); the voice activity
  /// model goes with the last speech model.
  Future<void> delete(String id) async {
    await whisper.delete(id);
    final vad = whisper.vadModel;
    if (vad != null &&
        id != vad.id &&
        (await whisper.installedModels()).isEmpty &&
        await whisper.models.installedModel(vad.id) != null) {
      await whisper.delete(vad.id);
    }
  }

  /// Installs the Whisper models (and the voice activity model) among the
  /// files at [paths] (picked by the user); never goes online. The last
  /// speech model installed becomes the one in use.
  Future<WhisperImportResult> importFiles(List<String> paths) async =>
      await _selectImported(
        await whisper.importFiles([for (final path in paths) File(path)]),
      );

  /// Installs the Whisper models (and the voice activity model) among the
  /// picked documents [sources], copied straight into the models folder
  /// (no copy elsewhere first, [WhisperSpeech.importSources]); never goes
  /// online. The last speech model installed becomes the one in use.
  Future<WhisperImportResult> importSources(
    List<WhisperImportSource> sources,
  ) async => await _selectImported(await whisper.importSources(sources));

  Future<WhisperImportResult> _selectImported(
    WhisperImportResult result,
  ) async {
    final speech = result.installed.where((model) => model != vadModel);
    if (speech.lastOrNull case final model?) await select(model.id);
    return result;
  }

  /// Transcribes 16 kHz mono [samples] with the model in use, in
  /// [language] (a Whisper or app code; null detects it).
  Future<WhisperTranscription> transcribe(
    Float32List samples, {
    String? language,
  }) async {
    final model = await _storedModel();
    return await whisper.transcribe(
      samples,
      language: language ?? 'auto',
      model: model,
    );
  }

  /// Stops a running [transcribe].
  Future<void> cancel() => whisper.cancel();

  /// Deletes every model and forgets the choice ("Delete all local
  /// data"). Every model is attempted; the first error is rethrown.
  Future<void> deleteAll() async {
    Object? failure;
    StackTrace? failureTrace;
    final installed = await whisper.models.installed();
    for (final model in installed) {
      try {
        await whisper.delete(model.id);
      } on Object catch (error, stackTrace) {
        failure ??= error;
        failureTrace ??= stackTrace;
      }
    }
    try {
      await _store.delete(modelKey);
    } on Object catch (error, stackTrace) {
      failure ??= error;
      failureTrace ??= stackTrace;
    }
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureTrace ?? StackTrace.current);
    }
  }

  /// Stops the engine isolate.
  Future<void> dispose() => whisper.dispose();

  Future<String?> _storedModel() async {
    try {
      return await _store.read(modelKey);
    } on Object {
      return null;
    }
  }
}

/// Whether a device with [memory] (null: unknown) has the RAM speech model
/// [model] needs ([WhisperCatalogModel.fitsMemory]): models without a
/// minimum fit everywhere; small and large-v3-turbo are not offered on
/// phones with too little RAM or on low-RAM (Android Go) devices.
bool voiceModelFitsMemory(WhisperCatalogModel model, DeviceMemory? memory) =>
    model.fitsMemory(
      totalBytes: memory?.totalBytes,
      lowRam: memory?.isLowRam ?? false,
    );
