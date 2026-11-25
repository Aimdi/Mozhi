import 'package:llama_engine/src/engine/llama_engine.dart';
import 'package:llama_engine/src/engine/web/llama_worker.dart';

/// Whether the native engine can run here: never on the web.
bool get llamaPlatformSupported => false;

/// An engine that is not available on this platform: every load,
/// generation and token count fails with [UnsupportedError].
LlamaEngine createLlamaEngine({
  String? libraryPath,
  String? variantGuardDirectory,
}) => const UnsupportedLlamaEngine();

/// No native library on the web: the baseline, which nothing runs.
LlamaEngineBuild llamaEngineBuild({
  String? libraryPath,
  String? variantGuardDirectory,
}) => const LlamaEngineBuild(
  variant: LlamaCpuVariant.baseline,
  library: 'libmozhi_llama.so',
);

/// No browser worker on platforms without `dart:js_interop`.
LlamaWorkerChannel? openLlamaWorker({String url = defaultLlamaWorkerUrl}) =>
    null;

/// No browser persistent storage on platforms without `dart:js_interop`.
Future<bool> requestPersistentLlamaStorage() async => false;

/// The engine on platforms without `dart:ffi` or `dart:js_interop`.
final class UnsupportedLlamaEngine implements LlamaEngine {
  const new();

  static final _unsupported = UnsupportedError(
    'On-device AI is not available on the web',
  );

  @override
  String? get loadedModelPath => null;

  @override
  Future<LlamaModelInfo> load(
    String modelPath, {
    int contextSize = 4096,
    int threads = 0,
  }) => Future.error(_unsupported);

  @override
  Stream<String> generate(LlamaGenerateRequest request) =>
      Stream.error(_unsupported);

  @override
  Future<int> countTokens(List<LlamaChatMessage> messages) =>
      Future.error(_unsupported);

  @override
  Future<void> cancel() async {}

  @override
  Future<void> unload() async {}

  @override
  Future<void> dispose() async {}
}
