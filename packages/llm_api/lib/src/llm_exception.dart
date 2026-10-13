/// Any failure talking to an LLM endpoint.
class LlmApiException implements Exception {
  const new(this.message, {this.statusCode, this.body});

  final String message;

  /// HTTP status, or null for transport errors / stream protocol errors.
  final int? statusCode;

  /// Raw response body (truncated to 2000 chars) for diagnostics.
  final String? body;

  bool get isAuthError => statusCode == 401 || statusCode == 403;
  bool get isRateLimited => statusCode == 429;
  bool get isNotFound => statusCode == 404;

  /// The server answered with a redirect (3xx). Redirects are never
  /// followed, so that API keys are not sent to another host; the base URL
  /// should be updated instead.
  bool get isRedirect => (statusCode ?? 0) ~/ 100 == 3;

  /// Whether this is an [LlmTruncatedException]: the model stopped at its
  /// output limit and the response is incomplete.
  bool get isTruncated => this is LlmTruncatedException;

  /// Whether this is an [LlmInterruptedException]: the response ended
  /// without the provider's end-of-response signal.
  bool get isInterrupted => this is LlmInterruptedException;

  @override
  String toString() => 'LlmApiException(${statusCode ?? '-'}): $message';
}

/// The model (or a provider safety system) declined to answer, e.g.
/// Anthropic `stop_reason: "refusal"` or Gemini `finishReason: "SAFETY"`.
/// Any partial output already streamed must be discarded by the caller.
class LlmRefusalException extends LlmApiException {
  const new(super.message, {this.category});

  /// Provider supplied category (Anthropic `stop_details.category`,
  /// Gemini block reason). May be null.
  final String? category;
}

/// The response was cut off because the model reached its output limit:
/// OpenAI-compatible `finish_reason: "length"`, Anthropic `stop_reason`
/// `"max_tokens"` / `"model_context_window_exceeded"`, Gemini
/// `finishReason: "MAX_TOKENS"` or Ollama `done_reason: "length"`.
///
/// Raised after the last text delta. [partialText] is everything that was
/// streamed (the concatenation of the deltas), so a caller can show it with
/// a warning, parse what is there, or retry with a larger
/// `LlmRequest.maxTokens`.
class LlmTruncatedException extends LlmApiException {
  const new({
    String message = defaultMessage,
    this.partialText = '',
    this.reason,
  }) : super(message);

  /// The message used when none is given.
  static const defaultMessage =
      'The response was cut off because the model reached its output limit.';

  /// The text streamed before the response was cut off.
  final String partialText;

  /// The provider's stop reason (e.g. `length`, `max_tokens`,
  /// `MAX_TOKENS`). May be null.
  final String? reason;
}

/// The response stream ended without the provider's end-of-response signal
/// (OpenAI-compatible `[DONE]` / `finish_reason`, Anthropic `message_stop` /
/// `stop_reason`, Gemini `finishReason`, Ollama `done: true`), or the
/// connection dropped while the response was streaming.
///
/// [partialText] is everything that was streamed before the interruption;
/// it is most likely incomplete.
class LlmInterruptedException extends LlmApiException {
  const new({String message = defaultMessage, this.partialText = ''})
    : super(message);

  /// The message used when none is given.
  static const defaultMessage =
      'The connection was interrupted before the response finished.';

  /// The text streamed before the interruption.
  final String partialText;
}
