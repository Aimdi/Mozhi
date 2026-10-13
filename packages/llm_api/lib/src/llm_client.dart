import 'package:http/http.dart' as http;
import 'package:llm_api/src/models.dart';
import 'package:llm_api/src/providers/anthropic_client.dart';
import 'package:llm_api/src/providers/gemini_client.dart';
import 'package:llm_api/src/providers/ollama_client.dart';
import 'package:llm_api/src/providers/openai_compatible_client.dart';

/// A chat client for one [LlmEndpoint].
///
/// Implementations (in `src/providers/`): [OpenAiCompatibleClient],
/// [AnthropicClient], [GeminiClient], [OllamaClient]. Construct through
/// [LlmClient.new] which dispatches on [LlmEndpoint.provider].
///
/// Contract for every implementation:
/// * [streamChat] yields *text deltas only* (never reasoning/thinking
///   content; OpenAI-compatible and Ollama output is piped through
///   `ThinkTagFilter`). The stream completes when the model finishes and
///   errors with `LlmApiException` / `LlmRefusalException` on failure,
///   including HTTP errors whose message is extracted from the provider's
///   JSON error body (`error.message`, `error`, `message`, `detail`).
/// * A response the model ended at its output limit errors with
///   `LlmTruncatedException` after the last delta (it carries the partial
///   text). A body that ends without the provider's end-of-response signal,
///   or a connection that drops while streaming, errors with
///   `LlmInterruptedException`.
/// * Requests honour [timeout] for connection + time-to-first-byte; once
///   streaming, an idle gap longer than [timeout] errors the stream.
/// * Redirects are never followed, because HTTP stacks forward custom auth
///   headers (`x-api-key`, `x-goog-api-key`) to the new host: a 3xx answer
///   errors with `LlmApiException` (`isRedirect`, message
///   `Redirected to <host> — update the base URL`).
/// * Cancelling the subscription aborts the HTTP request (use
///   `http.AbortableRequest` / close a per-request client).
/// * Works on web: uses only `package:http` (BrowserClient streams via
///   fetch); never `dart:io`.
abstract class LlmClient {
  /// Creates the client for [endpoint]'s provider.
  ///
  /// When [httpClient] is given it is used for all requests and is *not*
  /// closed by [close]; otherwise the client creates (and owns) one.
  factory(
    LlmEndpoint endpoint, {
    http.Client? httpClient,
    Duration timeout = defaultTimeout,
  }) => switch (endpoint.provider) {
    LlmProvider.openAiCompatible => OpenAiCompatibleClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
    ),
    LlmProvider.anthropic => AnthropicClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
    ),
    LlmProvider.gemini => GeminiClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
    ),
    LlmProvider.ollama => OllamaClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
    ),
  };

  /// Default [timeout]: generous because reasoning models can think for a
  /// long time before the first token and local servers may first have to
  /// load the model.
  static const defaultTimeout = Duration(seconds: 120);

  LlmEndpoint get endpoint;
  Duration get timeout;

  /// Streams text deltas for [request].
  Stream<String> streamChat(LlmRequest request);

  /// Convenience: the concatenation of [streamChat]. Throws the stream's
  /// error; an `LlmTruncatedException` / `LlmInterruptedException` carries
  /// the text received so far in `partialText`.
  Future<String> chat(LlmRequest request);

  /// Lists available models, sorted by id. Providers without a listing
  /// endpoint throw `LlmApiException`.
  Future<List<LlmModel>> listModels();

  /// Releases the HTTP client if owned.
  void close();
}
