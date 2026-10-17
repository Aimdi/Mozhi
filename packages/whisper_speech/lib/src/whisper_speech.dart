import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:whisper_speech/src/catalog.dart';
import 'package:whisper_speech/src/engine/engine_factory.dart';
import 'package:whisper_speech/src/engine/whisper_engine.dart';
import 'package:whisper_speech/src/languages.dart';
import 'package:whisper_speech/src/model_manager.dart';

/// No Whisper model is installed (download or import one first).
final class WhisperModelMissingException implements Exception {
  const new();

  @override
  String toString() => 'WhisperModelMissingException()';
}

/// Offline speech recognition: OpenAI's Whisper models on whisper.cpp, in
/// a background isolate, with verified model downloads and imports.
///
/// Nothing here records audio or goes online on its own: the app records
/// 16 kHz mono PCM (see `Pcm16Buffer`), calls [transcribe], and decides
/// when a model may be downloaded ([download], from
/// [WhisperCatalogModel.url]) or imports one from files ([importFiles]).
class WhisperSpeech {
  /// [root] is an app-private directory: models go to
  /// `<root>/models/<id>/`. [httpClient] downloads them (default: a new
  /// client). [engine] and [isAvailable] replace the platform's (tests).
  new({
    required this.catalog,
    required Directory root,
    http.Client? httpClient,
    WhisperEngine? engine,
    bool? isAvailable,
    Duration requestTimeout = const Duration(seconds: 60),
  }) : models = WhisperModelManager(
         root: root,
         httpClient: httpClient,
         requestTimeout: requestTimeout,
       ),
       _engine = engine ?? createWhisperEngine(),
       isAvailable = isAvailable ?? whisperPlatformSupported;

  /// The downloadable models, fastest first.
  final WhisperModelCatalog catalog;

  /// Downloads, imports and deletes the model files.
  final WhisperModelManager models;

  /// Whether the native engine runs on this device (Android on a supported
  /// CPU; never on the web).
  final bool isAvailable;

  final WhisperEngine _engine;

  /// The catalog models that are installed (the exact catalog file),
  /// fastest first.
  Future<List<WhisperCatalogModel>> installedModels() async {
    final installed = await models.installed();
    return [
      for (final model in catalog.models)
        if (installed.any((entry) => entry.matches(model))) model,
    ];
  }

  /// Whether [isAvailable] and at least one model is installed.
  Future<bool> isReady() async =>
      isAvailable && (await installedModels()).isNotEmpty;

  /// The installed model [transcribe] uses: [preferred] (a model id) when
  /// it is installed, else the most accurate installed one; null when none
  /// is installed.
  Future<InstalledWhisperModel?> modelFor({String? preferred}) async {
    final installed = await models.installed();
    InstalledWhisperModel? find(WhisperCatalogModel model) {
      for (final entry in installed) {
        if (entry.matches(model)) return entry;
      }
      return null;
    }

    if (preferred != null) {
      if (catalog.model(preferred) case final model?) {
        if (find(model) case final entry?) return entry;
      }
    }
    for (final model in catalog.models.reversed) {
      if (find(model) case final entry?) return entry;
    }
    return null;
  }

  /// Transcribes [pcm16k] (16 kHz mono samples in `-1..1`, e.g. from
  /// `Pcm16Buffer` or `pcm16ToFloat32`) in [language]: `auto` (detect),
  /// a Whisper code or any app / BCP-47 code ([whisperLanguageFor]; codes
  /// Whisper does not know are detected). [model] picks the model (see
  /// [modelFor]).
  ///
  /// Runs in a background isolate and takes about as long as the audio on
  /// a mid-range phone with the `tiny` model. Throws
  /// [WhisperModelMissingException] without an installed model,
  /// [WhisperCancelledException] after [cancel] and
  /// [WhisperEngineException] when the engine fails.
  Future<WhisperTranscription> transcribe(
    Float32List pcm16k, {
    String language = 'auto',
    String? model,
    int threads = 0,
  }) async {
    if (!isAvailable) {
      throw const WhisperEngineException(
        'Offline speech recognition is not available on this device',
      );
    }
    final installed = await modelFor(preferred: model);
    if (installed == null) throw const WhisperModelMissingException();
    return await _engine.transcribe(
      installed.path,
      pcm16k,
      language: whisperLanguageFor(language),
      threads: threads,
    );
  }

  /// Stops a running [transcribe] (it throws [WhisperCancelledException]).
  Future<void> cancel() => _engine.cancel();

  /// Downloads and installs [model] (resuming an interrupted download).
  /// Whether downloading is allowed now (Wi-Fi only, privacy settings) is
  /// for the caller to decide.
  Future<InstalledWhisperModel> download(
    WhisperCatalogModel model, {
    void Function(WhisperDownloadProgress progress)? onProgress,
  }) => models.install(model, onProgress: onProgress);

  /// Unloads and deletes the model [id] (and a partial download of it).
  Future<void> delete(String id) async {
    if (await models.installedModel(id) case final installed?) {
      await _engine.release(installed.path);
    }
    await models.delete(id);
  }

  /// Installs models from files copied to the device by hand
  /// ([WhisperModelManager.importFiles]); never goes online.
  Future<WhisperImportResult> importFiles(Iterable<File> files) =>
      models.importFiles(files, catalog: catalog);

  /// Removes leftovers of interrupted installs (safe at start-up).
  Future<void> cleanUp() => models.cleanUp();

  /// Stops the engine isolate and closes the HTTP client it created.
  Future<void> dispose() async {
    await _engine.dispose();
    models.close();
  }
}
