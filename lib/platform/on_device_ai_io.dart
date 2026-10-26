import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/platform/current_session_client.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/platform/metered_network.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:path_provider/path_provider.dart';

/// Folder of the app's support directory that holds the on-device AI
/// models (`<support>/llm/models/<id>/`).
const onDeviceAiFolder = 'llm';

/// Creates the on-device AI: [OnDeviceModels] with the bundled catalogue
/// ([bundle], default `rootBundle`), its models in the app-private
/// [supportDirectory] (default `getApplicationSupportDirectory()`: not
/// backed up, removed with the app), downloads through [httpClient]
/// (default: the current `NetworkSession`'s model client at the time of
/// each request, so the proxy setting applies and they are listed in
/// Network activity) and [isMeteredConnection] (default
/// [MeteredNetwork.isMetered]) for Wi-Fi-only downloads; and the llama.cpp
/// [engine] (default `createLlamaEngine()`: a background isolate, started
/// with the first request).
///
/// Returns null where llama.cpp cannot run ([llamaPlatformSupported]:
/// Android on arm64 or x86_64; [isAvailable] overrides it in tests) or the
/// catalogue or the directory cannot be loaded (logged). Leftovers of
/// interrupted installs are removed in the background.
///
/// A model (1-3 GB) is unloaded two minutes after the last request, when
/// the app goes to the background and on memory pressure ([memoryBudget],
/// default [NativeMemoryBudget.instance]); the next request loads it
/// again.
///
/// A download or import first checks the free space ([freeSpace], default
/// [FreeSpace.instance]); the engine turns off a faster build of its
/// library that crashed the app (its guard lives in [supportDirectory],
/// see `CpuVariantGuard`).
Future<OnDeviceAi?> createOnDeviceAi({
  required KeyValueStore store,
  AssetBundle? bundle,
  Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory,
  Future<bool> Function()? isMeteredConnection,
  http.Client? httpClient,
  bool? isAvailable,
  LlamaEngine? engine,
  NativeMemoryBudget? memoryBudget,
  Future<DeviceMemory?> Function() deviceMemory = DeviceMemory.query,
  FreeSpace? freeSpace,
}) async {
  if (!(isAvailable ?? llamaPlatformSupported)) return null;
  try {
    final (catalog, support, memory) = await (
      loadBundledLlamaCatalog(bundle: bundle),
      supportDirectory(),
      deviceMemory(),
    ).wait;
    final manager = LlamaModelManager(
      root: Directory(
        '${support.path}${Platform.pathSeparator}$onDeviceAiFolder',
      ),
      httpClient: httpClient ?? CurrentSessionClient(),
      freeSpace: (freeSpace ?? FreeSpace.instance).call,
    );
    unawaited(_cleanUp(manager));
    final models = OnDeviceModels(
      catalog: catalog,
      manager: manager,
      store: store,
      memory: memory,
      isMeteredConnection:
          isMeteredConnection ?? MeteredNetwork.instance.isMetered,
    );
    // The installed models and the choices (a few small files): the
    // engines are complete from the first screen on.
    await models.ready;
    return OnDeviceAi(
      models: models,
      // The native isolate engine (tests pass their own), guarded against
      // a faster build that crashes this phone.
      engine:
          engine ??
          // coverage:ignore-start
          createLlamaEngine(variantGuardDirectory: support.path),
      // coverage:ignore-end
      memoryBudget: memoryBudget ?? NativeMemoryBudget.instance,
      engineBuild: () => llamaEngineBuild(variantGuardDirectory: support.path),
    );
  } on Object catch (error, stackTrace) {
    final cause = error is ParallelWaitError ? error.errors : error;
    log(
      'On-device AI unavailable',
      name: 'mozhi',
      error: cause,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<void> _cleanUp(LlamaModelManager manager) async {
  try {
    await manager.cleanUp();
    // coverage:ignore-start
  } on Object catch (error, stackTrace) {
    // A start-up chore must never become an uncaught error.
    log(
      'On-device AI model clean-up failed',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }
  // coverage:ignore-end
}
