import 'package:bergamot_translator/src/model_manager.dart';
import 'package:translation_repository/translation_repository.dart';

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

/// A [BergamotEngine] that translates several texts in one native call,
/// with word alignment and quality scores on request, can load models
/// ahead of time, drops cancelled work and gives memory back.
///
/// A separate interface, so that every [BergamotEngine] keeps working:
/// `BergamotTranslator` uses these when its engine has them.
abstract interface class BergamotBatchEngine implements BergamotEngine {
  /// Translates [texts] through [chain] in one call (the engine batches
  /// their sentences together), one result per text, in order. With
  /// [details] every result has its sentences with word alignment and
  /// quality scores ([OfflineTranslation.sentences]; offsets relative to
  /// its text, [OfflineSentence.isLowConfidence] never set).
  ///
  /// Once [abort] completes, a request still waiting for the engine is
  /// dropped and fails with [OfflineTranslationCancelledException]; one
  /// already running finishes in the background, but its caller gets that
  /// exception at once.
  Future<List<OfflineTranslation>> translateBatch(
    List<ModelPaths> chain,
    List<String> texts, {
    bool html = false,
    bool details = false,
    Future<void>? abort,
  });

  /// Loads the models of [chain] (and keeps them like a translation
  /// through [chain] would), so that the next translation starts at once.
  Future<void> preload(List<ModelPaths> chain);

  /// Unloads every model but those of the most recent request (on memory
  /// pressure); they load again when needed.
  Future<void> trim();
}
