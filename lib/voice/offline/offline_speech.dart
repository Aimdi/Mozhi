import 'dart:io' show File;
import 'dart:typed_data';

import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart'
    show OfflineModelsCubit;
import 'package:whisper_speech/whisper_speech.dart';

/// A "Download over Wi-Fi only" download on a metered network: nothing was
/// downloaded (the settings ask whether to download anyway).
final class VoiceModelMeteredException implements Exception {
  const new();

  @override
  String toString() => 'VoiceModelMeteredException()';
}

/// The app's offline speech recognition: Whisper ([WhisperSpeech]) with
/// the model the user chose and the app's download rules.
///
/// * Downloads only happen when [download] is called (the user tapped
///   download), from Hugging Face ([WhisperCatalogModel.url]), and follow
///   the "Download over Wi-Fi only" setting of the offline languages
///   ([OfflineModelsCubit.wifiOnlyKey], default on): on a metered network
///   they throw [VoiceModelMeteredException] unless `overMeteredNetwork`.
/// * [importFiles] installs model files copied to the device by hand,
///   without any network request (for Offline only users).
/// * The model in use ([selected]) is stored under [modelKey]; without a
///   choice (or when it was deleted) the most accurate installed model is
///   used.
class OfflineSpeech {
  new({
    required this.whisper,
    required this._store,
    Future<bool> Function()? isMeteredConnection,
  }) : _isMetered = isMeteredConnection ?? _neverMetered;

  /// [KeyValueStore] key of the model in use ([WhisperCatalogModel.id]).
  static const modelKey = 'voice.offlineModel';

  final WhisperSpeech whisper;
  final KeyValueStore _store;
  final Future<bool> Function() _isMetered;

  static Future<bool> _neverMetered() async => false;

  /// Whether Whisper runs on this device.
  bool get isAvailable => whisper.isAvailable;

  /// The downloadable models, fastest first.
  List<WhisperCatalogModel> get models => whisper.catalog.models;

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
  /// the one in use. [onProgress] receives the fraction done (0 to 1).
  ///
  /// Throws [VoiceModelMeteredException] on a metered network when
  /// [wifiOnly] (unless [overMeteredNetwork]), [ArgumentError] for an
  /// unknown id, and the [WhisperModelInstallException]s of the download.
  Future<void> download(
    String id, {
    bool overMeteredNetwork = false,
    void Function(double fraction)? onProgress,
  }) async {
    final model = whisper.catalog.model(id);
    if (model == null) throw ArgumentError.value(id, 'id', 'Unknown model');
    if (!overMeteredNetwork && await wifiOnly() && await _isMetered()) {
      throw const VoiceModelMeteredException();
    }
    await whisper.download(
      model,
      onProgress: onProgress == null
          ? null
          : (progress) => onProgress(progress.fraction),
    );
    await select(id);
  }

  /// Deletes model [id] (and a partial download of it).
  Future<void> delete(String id) => whisper.delete(id);

  /// Installs the Whisper models among the files at [paths] (picked by the
  /// user); never goes online. The last model installed becomes the one in
  /// use.
  Future<WhisperImportResult> importFiles(List<String> paths) async {
    final result = await whisper.importFiles([
      for (final path in paths) File(path),
    ]);
    if (result.installed.lastOrNull case final model?) await select(model.id);
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
