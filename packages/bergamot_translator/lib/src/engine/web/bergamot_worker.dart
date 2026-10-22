import 'dart:typed_data';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';

/// What failed in a request to the web engine's worker
/// (`web/bergamot/worker.js`, see `docs/offline-engine.md`).
enum BergamotWorkerErrorKind {
  /// The WebAssembly engine failed (it restarts with the next request).
  engine,

  /// The browser's storage failed: no space left (quota), a private
  /// window, storage the user cleared.
  storage,

  /// A downloaded file did not match the catalog's size or SHA-256.
  checksum,

  /// A file or folder is not there.
  missing,

  /// The browser lacks something the engine needs, or the web app was
  /// built without the engine (`tool/build_wasm.sh`).
  unsupported,

  /// The request was malformed (a bug), or the worker could not be
  /// reached.
  protocol;

  /// The kind named [name] in a worker answer ([protocol] when unknown).
  static BergamotWorkerErrorKind of(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return protocol;
  }
}

/// A request to the web engine's worker failed.
final class BergamotWorkerException implements Exception {
  const new(this.kind, this.message);

  final BergamotWorkerErrorKind kind;
  final String message;

  /// The same failure as the [BergamotEngineException] the engine API
  /// reports.
  BergamotEngineException toEngineException() =>
      BergamotEngineException('${kind.name}: $message');

  @override
  String toString() => 'BergamotWorkerException(${kind.name}: $message)';
}

/// The connection to the web engine's worker (`web/bergamot/worker.js`):
/// one WebAssembly instance of the engine and CLD2, and the offline models
/// in the browser's Origin Private File System.
///
/// [request] sends `{id, op, ...arguments}`; the worker handles requests
/// one at a time, in order, and answers each with its result or an error
/// ([BergamotWorkerException]). Arguments and results are JSON-like
/// values (null, bool, num, String, List, Map with String keys) plus
/// [Uint8List]s. The browser implementation lives in
/// `js_bergamot_worker.dart`; tests use a fake.
abstract interface class BergamotWorkerChannel {
  /// Sends [op] with [arguments] and completes with the worker's result.
  /// Throws [BergamotWorkerException] when the worker reports an error or
  /// cannot be reached.
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
  ]);

  /// Stops the worker; pending requests fail with
  /// [BergamotWorkerErrorKind.protocol]. Later requests start a new one.
  void terminate();
}

/// Where the web app serves the worker (`web/bergamot/worker.js`),
/// relative to its base URL; the engine files are next to it.
const defaultBergamotWorkerUrl = 'bergamot/worker.js';
