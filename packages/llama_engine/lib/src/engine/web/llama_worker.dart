import 'dart:async';

import 'package:meta/meta.dart';

/// Default relative URL of the on-device AI WebAssembly worker
/// (`web/llama/worker.js`).
const defaultLlamaWorkerUrl = 'llama/worker.js';

/// Categories of errors reported by a [LlamaWorkerChannel].
enum LlamaWorkerErrorKind {
  engine,
  storage,
  checksum,
  missing,
  notLoaded,
  cancelled,
  unsupported,
  protocol;

  /// Parses [value] from a worker error payload; falls back to [engine].
  static LlamaWorkerErrorKind of(Object? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return engine;
  }
}

/// Failure from a [LlamaWorkerChannel] request.
@immutable
final class LlamaWorkerException implements Exception {
  const new(this.kind, this.message);

  final LlamaWorkerErrorKind kind;
  final String message;

  @override
  String toString() => 'LlamaWorkerException(${kind.name}, $message)';
}

/// Abstract RPC transport to `web/llama/worker.js` (implemented by
/// `JsLlamaWorkerChannel` on the web and faked in unit tests).
abstract interface class LlamaWorkerChannel {
  /// Sends one RPC operation and returns its result payload.
  ///
  /// When [onDelta] is supplied, streaming `{id, delta}` frames arriving
  /// before the final `{id, ok}` reply are delivered in order.
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
    void Function(String delta)? onDelta,
  ]);

  /// Terminates the underlying worker and fails any in-flight requests.
  void terminate();
}
