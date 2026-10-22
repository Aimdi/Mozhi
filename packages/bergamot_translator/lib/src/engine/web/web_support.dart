import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
import 'package:bergamot_translator/src/engine/web/worker_values.dart';
import 'package:meta/meta.dart';

/// Something the web engine needs that a browser may lack, from the most
/// actionable for the user to the least.
enum BergamotWebRequirement {
  /// The web app was built without the engine files
  /// (`web/bergamot/bergamot-translator.{js,wasm}`, see
  /// `tool/build_wasm.sh`), or the worker cannot start (blocked by the
  /// server's Content-Security-Policy, ...).
  engineFiles,

  /// A secure context (HTTPS or localhost): the private storage and
  /// `crypto.subtle` exist only there.
  secureContext,

  /// The Origin Private File System, with synchronous access from a worker
  /// (missing in some private windows and old browsers).
  storage,

  /// WebAssembly SIMD (Chrome and Edge 91+, Firefox 89+, Safari 16.4+).
  wasmSimd,

  /// `DecompressionStream('gzip')` (Chrome 80+, Firefox 113+, Safari
  /// 16.4+).
  decompression,

  /// `Intl.Segmenter` (sentence splitting: Chrome 87+, Firefox 125+, Safari
  /// 14.1+).
  segmenter,
}

/// What the browser has of what the web engine needs (the worker's `probe`
/// answer).
@immutable
final class BergamotWebSupport {
  const new({this.missing = const {}, this.persisted = false});

  /// The worker could not be reached at all.
  const new unavailable()
    : missing = const {BergamotWebRequirement.engineFiles},
      persisted = false;

  /// Reads the worker's `probe` answer (`{simd, opfs, syncAccess,
  /// decompression, digest, segmenter, engine, secure, persisted}`).
  factory fromProbe(Object? json) {
    final probe = json.asMap;
    bool has(String name) => probe[name].asBool;
    final secure = has('secure');
    return BergamotWebSupport(
      missing: {
        if (!has('engine')) BergamotWebRequirement.engineFiles,
        if (!secure || !has('digest')) BergamotWebRequirement.secureContext,
        if (secure && (!has('opfs') || !has('syncAccess')))
          BergamotWebRequirement.storage,
        if (!has('simd')) BergamotWebRequirement.wasmSimd,
        if (!has('decompression')) BergamotWebRequirement.decompression,
        if (!has('segmenter')) BergamotWebRequirement.segmenter,
      },
      persisted: has('persisted'),
    );
  }

  /// What is missing; empty when the engine can run.
  final Set<BergamotWebRequirement> missing;

  /// Whether the browser already keeps this site's storage persistently.
  final bool persisted;

  bool get isSupported => missing.isEmpty;

  /// The first of [missing] in [BergamotWebRequirement] order (the one to
  /// tell the user about), or null.
  BergamotWebRequirement? get reason {
    for (final requirement in BergamotWebRequirement.values) {
      if (missing.contains(requirement)) return requirement;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is BergamotWebSupport &&
      other.persisted == persisted &&
      other.missing.length == missing.length &&
      other.missing.containsAll(missing);

  @override
  int get hashCode => Object.hash(persisted, Object.hashAllUnordered(missing));

  @override
  String toString() =>
      'BergamotWebSupport(${isSupported ? 'supported' : missing})';
}

/// Asks the worker behind [channel] what the browser supports (it does not
/// start the engine). [BergamotWebSupport.unavailable] when the worker does
/// not answer within [timeout] or fails.
Future<BergamotWebSupport> probeBergamotWorker(
  BergamotWorkerChannel channel, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    return BergamotWebSupport.fromProbe(
      await channel.request('probe').timeout(timeout),
    );
  } on Object {
    return const BergamotWebSupport.unavailable();
  }
}
