import 'dart:typed_data';

import 'package:llm_api/llm_api.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/src/models/models.dart';

typedef MozhiClientFactory = MozhiApiClient Function(Uri baseUrl);
typedef LlmClientFactory = LlmClient Function(LlmEndpoint endpoint);

/// The single entry point the app uses for anything translation related.
///
/// Configuration is pushed by the app whenever settings change
/// ([updateConfiguration]). Mozhi requests go to the first reachable
/// instance in [instances] order: on a retryable `MozhiApiException`
/// (network/timeout/429/5xx) the next instance is tried and, on success,
/// becomes the preferred one for the session ([activeInstance]).
/// Language lists and engine lists are cached in memory per instance+engine
/// (cleared by [updateConfiguration] when instances change, or
/// `refresh: true`).
class TranslationRepository {
  new() {
    throw UnimplementedError('TODO(translation_repository)');
  }

  void updateConfiguration({
    required List<MozhiInstance> instances,
    required List<AiProviderConfig> providers,
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  List<MozhiInstance> get instances => throw UnimplementedError();
  List<AiProviderConfig> get providers => throw UnimplementedError();

  /// Instance currently preferred for Mozhi calls (null when none).
  MozhiInstance? get activeInstance => throw UnimplementedError();

  /// Engines: Mozhi engines advertised by the active instance (via
  /// `/api/engines`, `subtitle` = instance host) followed by enabled AI
  /// providers (`name` = provider name, `subtitle` = model, `isLocal`).
  /// If no instance is reachable, returns only AI engines (and does not
  /// throw) unless there are none, in which case the last error is thrown.
  Future<List<TranslationEngine>> getEngines({bool refresh = false}) =>
      throw UnimplementedError();

  /// Mozhi: `/api/source_languages` mapped to [Language] (id `auto` ->
  /// [Language.auto] first, names from the engine, `nativeName` from
  /// `LanguageCatalog` when known). AI: [Language.auto] + catalogue.
  Future<List<Language>> getSourceLanguages(TranslationEngine engine) =>
      throw UnimplementedError();

  /// Mozhi: `/api/target_languages`. AI: catalogue.
  Future<List<Language>> getTargetLanguages(TranslationEngine engine) =>
      throw UnimplementedError();

  /// Mozhi: one complete result (with transliterations, word choices,
  /// synonyms; `detectedSource` normalised). AI: streams growing snapshots
  /// (`isComplete: false`) and a final `isComplete: true` result; the
  /// `[[lang:xx]]` marker is parsed into `detectedSource` and never shown;
  /// `<think>` content never appears; text is passed through
  /// `ResponseParsers.cleanTranslation` on completion. Empty/whitespace
  /// input emits nothing and completes. Errors are forwarded as-is
  /// (`MozhiApiException`, `LlmApiException`, `LlmRefusalException`).
  /// Cancelling the subscription cancels the underlying HTTP request.
  Stream<TranslationResult> translate(
    TranslationEngine engine,
    TranslationRequest request,
  ) => throw UnimplementedError();

  /// Runs [engines] concurrently and emits a [CompareEntry] per engine as
  /// soon as it finishes (only final results; failures as
  /// `CompareEntry.failure`). Mozhi engines are batched into a single
  /// `translateWithEngines` call when 2+ Mozhi engines are requested, with
  /// engines missing from the batch response reported as failures.
  Stream<CompareEntry> compare(
    List<TranslationEngine> engines,
    TranslationRequest request,
  ) => throw UnimplementedError();

  Future<AlternativeTranslations> getAlternatives(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    int count = 3,
    String? span,
    String uiLanguage = 'English',
  }) => throw UnimplementedError();

  Future<List<WordInsight>> getInsights(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) => throw UnimplementedError();

  Future<List<RefinementSuggestion>> getSuggestions(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) => throw UnimplementedError();

  /// Streams Markdown.
  Stream<String> explain(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String? question,
    String uiLanguage = 'English',
  }) => throw UnimplementedError();

  Future<DictionaryEntry> lookUp(
    TranslationEngine engine,
    String word, {
    required Language source,
    required Language target,
    String context = '',
    String uiLanguage = 'English',
  }) => throw UnimplementedError();

  Future<ProofreadResult> proofread(
    TranslationEngine engine,
    String text, {
    WritingStyle style = WritingStyle.general,
    CorrectionLevel level = CorrectionLevel.standard,
    Formality formality = Formality.automatic,
    String context = '',
    String uiLanguage = 'English',
  }) => throw UnimplementedError();

  /// Uses the AI [engine] when given, else Mozhi google with `from=auto`
  /// (taking `detected`), else throws.
  Future<DetectedLanguage> detectLanguage(
    String text, {
    TranslationEngine? engine,
  }) => throw UnimplementedError();

  /// Mozhi `/api/tts` on the active instance with failover. [engine] is
  /// `google` (default) or `reverso`.
  Future<Uint8List> textToSpeech({
    required String text,
    required String languageCode,
    String engine = 'google',
  }) => throw UnimplementedError();

  /// AI engine with vision: `TranslationPrompts.translateImage`.
  /// Mozhi engine: `/api/image` (requires PNG; Google only).
  Future<ImageTranslationResult> translateImage(
    TranslationEngine engine,
    Uint8List imageBytes, {
    required String mimeType,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
  }) => throw UnimplementedError();

  /// Latency of `/api/version` on [instance]; throws on failure.
  Future<Duration> pingInstance(MozhiInstance instance) =>
      throw UnimplementedError();

  Future<List<LlmModel>> listModels(AiProviderConfig config) =>
      throw UnimplementedError();

  /// Sends a tiny translation ("Hello" -> French) with [config]; returns the
  /// output; throws the provider error on failure.
  Future<String> testProvider(AiProviderConfig config) =>
      throw UnimplementedError();

  /// Closes all cached HTTP clients.
  void dispose() => throw UnimplementedError();
}
