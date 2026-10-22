import 'dart:io' show Directory;

import 'package:bergamot_translator/src/bergamot_translator.dart';
import 'package:bergamot_translator/src/catalog.dart';
import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
import 'package:bergamot_translator/src/engine/web/opfs_model_manager.dart';
import 'package:bergamot_translator/src/engine/web/web_support.dart';
import 'package:bergamot_translator/src/engine/web/worker_engine.dart';
import 'package:bergamot_translator/src/engine/web/worker_language_identifier.dart';
import 'package:http/http.dart' as http;

export 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
export 'package:bergamot_translator/src/engine/web/opfs_model_manager.dart';
export 'package:bergamot_translator/src/engine/web/web_support.dart';
export 'package:bergamot_translator/src/engine/web/worker_engine.dart';
export 'package:bergamot_translator/src/engine/web/worker_language_identifier.dart';

/// The web app's [BergamotTranslator]: the same catalog, routing (pivots
/// through English), chunking, batching and CLD2 decision as the Android
/// app, with the WebAssembly engine and CLD2 in the worker behind
/// [channel] ([WorkerBergamotEngine], [WorkerLanguageIdentifier]) and the
/// models in the browser's storage ([OpfsModelManager], downloads through
/// [httpClient]).
///
/// [isAvailable] comes from [probeBergamotWorker]. [isMeteredConnection]
/// defaults to "never" (most browsers cannot tell);
/// [requestPersistence] asks the browser to keep the models (see
/// `requestPersistentBrowserStorage`). The worker keeps [maxLoadedModels]
/// models loaded with a Marian workspace of [workspaceMb].
BergamotTranslator createWebBergamotTranslator({
  required ModelCatalog catalog,
  required BergamotWorkerChannel channel,
  required http.Client httpClient,
  required bool isAvailable,
  Future<bool> Function()? isMeteredConnection,
  Future<bool> Function()? requestPersistence,
  int maxLoadedModels = 2,
  int workspaceMb = 32,
}) => BergamotTranslator(
  catalog: catalog,
  root: Directory(OpfsModelManager.rootFolder),
  isMeteredConnection: isMeteredConnection ?? _never,
  models: OpfsModelManager(
    channel: channel,
    httpClient: httpClient,
    requestPersistence: requestPersistence,
  ),
  engine: WorkerBergamotEngine(
    channel,
    maxLoadedModels: maxLoadedModels,
    workspaceMb: workspaceMb,
  ),
  languageId: WorkerLanguageIdentifier(channel),
  isAvailable: isAvailable,
);

Future<bool> _never() async => false;
