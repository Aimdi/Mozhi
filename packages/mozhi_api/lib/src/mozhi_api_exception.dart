/// Thrown when a request to a Mozhi instance fails.
///
/// [statusCode] is `null` for transport failures (DNS, TLS, timeouts,
/// unparsable bodies). For HTTP errors Mozhi answers with a plain-text body
/// that is surfaced as [message].
class MozhiApiException implements Exception {
  const new(this.message, {this.statusCode, this.uri});

  final String message;
  final int? statusCode;
  final Uri? uri;

  /// Statuses that another instance would answer the same way: Mozhi's own
  /// validation errors (400: missing parameters, an image that is not a PNG)
  /// and the request size limits every stock Fiber instance shares.
  static const _requestErrors = {400, 413, 414, 431};

  /// Whether retrying against another instance could plausibly succeed.
  ///
  /// True for network errors, timeouts and every status except 400, 413,
  /// 414 and 431, which any instance would repeat. Mozhi reports engine
  /// failures, including an unsupported language, as 500; any other 3xx or
  /// 4xx (403 challenge pages, 404 parked domains, 401 basic auth, 405, 408,
  /// 429, a redirected POST) comes from whatever sits in front of that one
  /// instance.
  bool get isRetryable =>
      statusCode == null || !_requestErrors.contains(statusCode);

  /// Includes [uri] without user info, query and fragment, so credentials
  /// and the user's text (`/api/tts?text=…`) never reach logs.
  @override
  String toString() {
    final uri = this.uri;
    final shown = uri == null
        ? null
        : Uri(
            scheme: uri.scheme,
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            path: uri.path,
          );
    return 'MozhiApiException(${statusCode ?? 'network'}): $message'
        '${shown == null ? '' : ' [$shown]'}';
  }
}

/// Thrown when the caller completed a request's `abortTrigger`: the request
/// was aborted and its result will never be delivered.
///
/// Never retryable: the caller gave up on the request, so it must not be
/// sent to another instance either.
class MozhiRequestCancelledException extends MozhiApiException {
  const new({super.uri}) : super('The request was cancelled.');

  @override
  bool get isRetryable => false;
}
