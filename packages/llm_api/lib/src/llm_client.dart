import 'package:http/http.dart' as http;
import 'package:llm_api/src/models.dart';
import 'package:llm_api/src/providers/anthropic_client.dart';
import 'package:llm_api/src/providers/gemini_client.dart';
import 'package:llm_api/src/providers/ollama_client.dart';
import 'package:llm_api/src/providers/openai_compatible_client.dart';
import 'package:llm_api/src/retry_policy.dart';

/// A chat client for one [LlmEndpoint].
///
/// Implementations (in `src/providers/`): [OpenAiCompatibleClient],
/// [AnthropicClient], [GeminiClient], [OllamaClient]. Construct through
/// [LlmClient.new] which dispatches on [LlmEndpoint.provider]. Clients of
/// [LlmProvider.onDevice] endpoints (models running in the app) implement
/// this interface outside the package; they follow the same contract
/// without the HTTP parts.
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
/// * A transient failure (`LlmApiException.isTransient`: 429, 500, 502,
///   503, 504, 529 or a dropped connection, including such an error event
///   at the start of the stream) is retried as the client's
///   [LlmRetryPolicy] allows (once by default), but only while no text
///   delta has been emitted, so visible output is never paid for twice.
///   `Retry-After` is honoured up to `LlmRetryPolicy.maxRetryAfter`.
/// * Redirects are never followed, because HTTP stacks forward custom auth
///   headers (`x-api-key`, `x-goog-api-key`) to the new host: a 3xx answer
///   errors with `LlmApiException` (`isRedirect`, message
///   `Redirected to <host> — update the base URL`).
/// * Cancelling the subscription aborts the HTTP request (use
///   `http.AbortableRequest` / close a per-request client).
/// * Works on web: uses only `package:http` (BrowserClient streams via
///   fetch); never `dart:io`.
abstract class LlmClient {
  /// Creates the client for [endpoint]'s provider ([UnsupportedError] for
  /// [LlmProvider.onDevice]: models on this device run inside the app,
  /// which supplies their client).
  ///
  /// When [httpClient] is given it is used for all requests and is *not*
  /// closed by [close]; otherwise the client creates (and owns) one.
  ///
  /// [retryPolicy] decides when [streamChat] retries a transient failure
  /// ([LlmRetryPolicy.none] turns retries off). [keepAlive] is how long a
  /// local server keeps the model loaded after a request (Ollama
  /// `keep_alive`; negative means forever); null leaves it to the server.
  /// Cloud providers ignore it.
  factory(
    LlmEndpoint endpoint, {
    http.Client? httpClient,
    Duration timeout = defaultTimeout,
    LlmRetryPolicy retryPolicy = LlmRetryPolicy.standard,
    Duration? keepAlive,
  }) => switch (endpoint.provider) {
    LlmProvider.openAiCompatible => OpenAiCompatibleClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
      retryPolicy: retryPolicy,
    ),
    LlmProvider.anthropic => AnthropicClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
      retryPolicy: retryPolicy,
    ),
    LlmProvider.gemini => GeminiClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
      retryPolicy: retryPolicy,
    ),
    LlmProvider.ollama => OllamaClient(
      endpoint,
      httpClient: httpClient,
      timeout: timeout,
      retryPolicy: retryPolicy,
      keepAlive: keepAlive,
    ),
    LlmProvider.onDevice => throw UnsupportedError(
      'On-device models have no HTTP client: the app supplies their client',
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

  /// Asks a local server to load [model] now (and keep it loaded for the
  /// client's keep-alive), so that the first request does not wait for the
  /// model to load. Meant to be called, without awaiting, when the user
  /// selects a local engine.
  ///
  /// Ollama: an empty `POST {base}/api/generate` with the `num_ctx` that
  /// later chat requests will use (a different one would reload the
  /// model). Every other provider does nothing. Never throws: answers
  /// whether the server confirmed that the model is loaded (false for
  /// providers without warm-up and on any failure). Sends no user text.
  Future<bool> warmUp(String model);

  /// Releases the HTTP client if owned.
  void close();
}
