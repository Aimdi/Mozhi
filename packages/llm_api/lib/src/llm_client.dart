import 'package:llm_api/src/models.dart';

/// A chat client for one [LlmEndpoint].
///
/// Implementations (in `src/providers/`): `OpenAiCompatibleClient`,
/// `AnthropicClient`, `GeminiClient`, `OllamaClient`. Construct through
/// [LlmClient.new] which dispatches on [LlmEndpoint.provider].
///
/// Contract for every implementation:
/// * [streamChat] yields *text deltas only* (never reasoning/thinking
///   content; OpenAI-compatible and Ollama output is piped through
///   `ThinkTagFilter`). The stream completes when the model finishes and
///   errors with `LlmApiException` / `LlmRefusalException` on failure,
///   including HTTP errors whose message is extracted from the provider's
///   JSON error body (`error.message`, `error`, `message`, `detail`).
/// * Requests honour [timeout] for connection + time-to-first-byte; once
///   streaming, an idle gap longer than [timeout] errors the stream.
/// * Cancelling the subscription aborts the HTTP request (use
///   `http.AbortableRequest` / close a per-request client).
/// * Works on web: uses only `package:http` (BrowserClient streams via
///   fetch); never `dart:io`.
abstract class LlmClient {
  factory() {
    throw UnimplementedError('TODO(llm_api): dispatch to provider client');
  }

  LlmEndpoint get endpoint;
  Duration get timeout;

  /// Streams text deltas for [request].
  Stream<String> streamChat(LlmRequest request);

  /// Convenience: the concatenation of [streamChat].
  Future<String> chat(LlmRequest request);

  /// Lists available models, sorted by id. Providers without a listing
  /// endpoint throw `LlmApiException`.
  Future<List<LlmModel>> listModels();

  /// Releases the HTTP client if owned.
  void close();
}
