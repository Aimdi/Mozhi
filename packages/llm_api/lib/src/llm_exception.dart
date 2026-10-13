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
