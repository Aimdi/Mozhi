// Browser-side engine factory (dart:js_interop only).
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llama_engine/src/engine/llama_engine.dart';
import 'package:llama_engine/src/engine/web/js_llama_worker.dart';
import 'package:llama_engine/src/engine/web/llama_worker.dart';
import 'package:llama_engine/src/engine/web/web_llama_engine.dart';

export 'package:llama_engine/src/engine/web/js_llama_worker.dart'
    show JsLlamaWorkerChannel;

/// Whether the native FFI engine can run here: never in a browser. The web
/// engine (WebAssembly in a worker) depends on browser capabilities and the
/// deployed WASM artifact: ask `probeLlamaWorker(openLlamaWorker()!)`.
bool get llamaPlatformSupported => false;

/// The web engine: llama.cpp compiled to WebAssembly running in the shared
/// worker ([openLlamaWorker]). [libraryPath] and [variantGuardDirectory] are
/// ignored.
LlamaEngine createLlamaEngine({
  String? libraryPath,
  String? variantGuardDirectory,
}) => WebLlamaEngine(openLlamaWorker()!);

/// Engine build metadata on the web (WebAssembly build).
LlamaEngineBuild llamaEngineBuild({
  String? libraryPath,
  String? variantGuardDirectory,
}) => const LlamaEngineBuild(
  variant: LlamaCpuVariant.baseline,
  library: 'llama-engine.wasm',
);

final _workers = <String, LlamaWorkerChannel>{};

/// The worker running `web/llama/worker.js` at [url] (one per URL, started
/// lazily on its first request). Null only on platforms without browser
/// workers.
LlamaWorkerChannel? openLlamaWorker({String url = defaultLlamaWorkerUrl}) =>
    _workers[url] ??= JsLlamaWorkerChannel(url);

/// Asks the browser for persistent OPFS storage (`navigator.storage.persist()`)
/// so downloaded GGUF models are not evicted under storage pressure.
Future<bool> requestPersistentLlamaStorage() async {
  try {
    final navigator = globalContext['navigator'];
    if (!navigator.isA<JSObject>()) return false;
    final storage = (navigator! as JSObject)['storage'];
    if (!storage.isA<JSObject>()) return false;
    final storageObj = storage! as JSObject;
    if (!storageObj.has('persist')) return false;
    final result = await storageObj
        .callMethod<JSPromise<JSBoolean>>('persist'.toJS)
        .toDart;
    return result.toDart;
  } on Object {
    return false;
  }
}
