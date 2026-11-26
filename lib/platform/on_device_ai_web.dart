import 'dart:async';
import 'dart:developer';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/platform/browser_network.dart';
import 'package:mozhi/platform/current_session_client.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:mozhi/settings/models/web_base_url.dart';

/// Creates the web app's on-device AI backed by `WebLlamaEngine` and
/// `WebLlamaModelManager` (OPFS storage in `web/llama/worker.js`), mirroring
/// `lib/platform/offline_engine_web.dart`.
///
/// Returns `null` gracefully (never throws) when:
/// * no browser worker channel is available (e.g. VM/non-browser runtimes),
/// * the browser lacks WebAssembly / OPFS / Web Crypto or `llama-engine.wasm`
///   is not deployed on this origin,
/// * the deployment uses [ModelSourceKind.thisServer] without fallback, has no
///   models installed in OPFS yet, and `<host>/models/llm/index.json` is absent,
/// * or loading the bundled catalog fails.
Future<OnDeviceAi?> createOnDeviceAi({
  required KeyValueStore store,
  AssetBundle? bundle,
  LlamaWorkerChannel? channel,
  http.Client? httpClient,
  Future<bool> Function()? isMeteredConnection,
  Future<bool> Function()? requestPersistence,
  Future<int?> Function()? freeSpace,
  ModelSource Function()? modelSource,
  Uri? Function()? hostBaseUrl,
}) async {
  final ownedWorker = channel == null;
  final worker = channel ?? openLlamaWorker();
  if (worker == null) return null;

  final client = httpClient ?? CurrentSessionClient();
  final source = (modelSource ?? () => ModelSource.current)();
  final baseUrl = (hostBaseUrl ?? webAppBaseUrl)();

  try {
    final (support, catalog) = await (
      probeLlamaWorker(worker),
      loadBundledLlamaCatalog(bundle: bundle),
    ).wait;
    if (!support.supported) {
      log('Web on-device AI unavailable: $support', name: 'mozhi');
      if (ownedWorker) worker.terminate();
      return null;
    }

    final manager = WebLlamaModelManager(
      channel: worker,
      httpClient: client,
      requestPersistence: requestPersistence ?? requestPersistentLlamaStorage,
      freeSpace: freeSpace ?? FreeSpace.instance.availableBytes,
    );
    unawaited(_cleanUp(manager));

    final models = OnDeviceModels(
      catalog: catalog,
      manager: manager,
      store: store,
      isMeteredConnection: isMeteredConnection ?? browserConnectionIsMetered,
      modelSource: modelSource,
    );
    await models.ready;

    // When configured to download exclusively from this host, probe
    // `models/llm/index.json` so a web deployment without mirrored LLM files
    // reports unavailable cleanly unless a model is already cached in OPFS.
    final hasInstalled =
        models.translationModel != null || models.assistantModel != null;
    if (!hasInstalled &&
        source.kind == ModelSourceKind.thisServer &&
        !source.fallsBackToDefault &&
        baseUrl != null) {
      final probe = await manager.probeHostMirror(baseUrl);
      if (!probe.available) {
        log('Web on-device AI mirror unavailable at $baseUrl', name: 'mozhi');
        await models.dispose();
        if (ownedWorker) worker.terminate();
        return null;
      }
    }

    return OnDeviceAi(
      models: models,
      engine: WebLlamaEngine(worker),
      engineBuild: llamaEngineBuild,
    );
  } on Object catch (error, stackTrace) {
    final cause = error is ParallelWaitError ? error.errors : error;
    log(
      'Web on-device AI unavailable',
      name: 'mozhi',
      error: cause,
      stackTrace: stackTrace,
    );
    if (ownedWorker) worker.terminate();
    return null;
  }
}

Future<void> _cleanUp(WebLlamaModelManager manager) async {
  try {
    await manager.cleanUp();
  } on Object catch (error, stackTrace) {
    log(
      'Web on-device AI model clean-up failed',
      name: 'mozhi',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
