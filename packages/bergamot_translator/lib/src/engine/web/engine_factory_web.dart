import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
import 'package:bergamot_translator/src/engine/web/js_bergamot_worker.dart';
import 'package:bergamot_translator/src/engine/web/web_support.dart';
import 'package:bergamot_translator/src/engine/web/worker_engine.dart';
import 'package:bergamot_translator/src/engine/web/worker_language_identifier.dart';
import 'package:bergamot_translator/src/native_language_identifier.dart';

export 'package:bergamot_translator/src/engine/web/js_bergamot_worker.dart'
    show requestPersistentBrowserStorage;

/// Whether the native engine can run here: never in a browser. The web
/// engine (WebAssembly in a worker) depends on the browser: ask
/// [probeBergamotWorker] with [openBergamotWorker].
bool get bergamotPlatformSupported => false;

/// The web engine: the WebAssembly engine in the shared worker
/// ([openBergamotWorker]). [libraryPath] is ignored.
BergamotEngine createBergamotEngine({
  String? libraryPath,
  int maxLoadedModels = 3,
}) => WorkerBergamotEngine(
  openBergamotWorker()!,
  maxLoadedModels: maxLoadedModels < 2 ? 2 : maxLoadedModels,
);

/// CLD2 in the shared worker's WebAssembly engine. [libraryPath] is
/// ignored.
NativeLanguageIdentifier createNativeLanguageIdentifier({
  String? libraryPath,
}) => WorkerLanguageIdentifier(openBergamotWorker()!);

final _workers = <String, BergamotWorkerChannel>{};

/// The worker running `web/bergamot/worker.js` at [url] (one per URL,
/// started with its first request). Null only on platforms without one.
BergamotWorkerChannel? openBergamotWorker({
  String url = defaultBergamotWorkerUrl,
}) => _workers[url] ??= JsBergamotWorkerChannel(url);
