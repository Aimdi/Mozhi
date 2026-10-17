import 'package:bergamot_translator/src/model_manager.dart';

/// The native engine failed (it could not be loaded, a model could not be
/// opened, or a translation failed). The message comes from the engine.
final class BergamotEngineException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'BergamotEngineException($message)';
}

/// Runs the Bergamot engine (`libmozhi_bergamot`), off the UI isolate.
///
/// Implementations load each model lazily on first use and keep a few
/// loaded ([ModelPaths.key] identifies them).
abstract interface class BergamotEngine {
  /// Translates [text] through [chain]: one model, or two for a pivot
  /// (source -> English -> target). With [html] markup is preserved.
  Future<String> translate(
    List<ModelPaths> chain,
    String text, {
    bool html = false,
  });

  /// Unloads the model with [key] if it is loaded (e.g. before deleting
  /// its files).
  Future<void> release(String key);

  /// Unloads every model and stops the background isolate. The engine stays
  /// usable; the next call starts it again.
  Future<void> dispose();
}
