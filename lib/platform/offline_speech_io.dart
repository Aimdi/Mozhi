import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/platform/offline_engine_io.dart'
    show CurrentSessionClient;
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Folder of the app's support directory that holds the Whisper models
/// (`<support>/whisper/models/<id>/`).
const offlineSpeechFolder = 'whisper';

/// How long the Whisper model stays loaded after the last transcription.
const speechModelIdleTimeout = Duration(seconds: 60);

/// Creates the offline speech recognition: [WhisperSpeech] with the
/// bundled model catalog ([bundle], default `rootBundle`), its models in
/// the app-private [supportDirectory] (default
/// `getApplicationSupportDirectory()`: not backed up, removed with the
/// app), downloads through [httpClient] (default: the current
/// `NetworkSession`'s client at the time of each request, so the proxy
/// setting applies) and [isMeteredConnection] (default
/// [MeteredNetwork.isMetered]) for Wi-Fi-only downloads.
///
/// Returns null where Whisper cannot run ([whisperPlatformSupported]:
/// Android on a supported CPU; [isAvailable] overrides it in tests) or the
/// catalog or the directory cannot be loaded (logged). Leftovers of
/// interrupted installs are removed in the background.
///
/// The model (75-150 MB) is unloaded after [speechModelIdleTimeout]
/// without a transcription, when the app goes to the background and on
/// memory pressure ([memoryBudget], default [NativeMemoryBudget.instance]);
/// the next transcription loads it again.
Future<OfflineSpeech?> createOfflineSpeech({
  required KeyValueStore store,
  AssetBundle? bundle,
  Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory,
  Future<bool> Function()? isMeteredConnection,
  http.Client? httpClient,
  bool? isAvailable,
  WhisperEngine? engine,
  NativeMemoryBudget? memoryBudget,
}) async {
  if (!(isAvailable ?? whisperPlatformSupported)) return null;
  try {
    final (catalog, support) = await (
      loadBundledWhisperCatalog(bundle: bundle),
      supportDirectory(),
    ).wait;
    final whisper = WhisperSpeech(
      catalog: catalog,
      root: Directory(
        '${support.path}${Platform.pathSeparator}$offlineSpeechFolder',
      ),
      httpClient: httpClient ?? CurrentSessionClient(),
      engine: engine,
      isAvailable: true,
      idleUnloadAfter: speechModelIdleTimeout,
    );
    unawaited(_cleanUp(whisper));
    (memoryBudget ?? NativeMemoryBudget.instance)
      ..onBackground(whisper.unload)
      ..onMemoryPressure(whisper.unload);
    return OfflineSpeech(
      whisper: whisper,
      store: store,
      isMeteredConnection:
          isMeteredConnection ?? MeteredNetwork.instance.isMetered,
    );
  } on Object catch (error, stackTrace) {
    final cause = error is ParallelWaitError ? error.errors : error;
    log(
      'Offline speech recognition unavailable',
      name: 'mozhi',
      error: cause,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<void> _cleanUp(WhisperSpeech whisper) async {
  try {
    await whisper.cleanUp();
    // coverage:ignore-start
  } on Object catch (error, stackTrace) {
    // cleanUp() already ignores file system errors; this is a safety net
    // so that a start-up chore can never become an uncaught error.
    log(
      'Offline speech model clean-up failed',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }
  // coverage:ignore-end
}
