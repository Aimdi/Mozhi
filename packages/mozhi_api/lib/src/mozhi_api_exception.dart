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

  /// Deterministic Mozhi server validation errors that the Go server reports
  /// as HTTP 500 (every instance would repeat them, so failing over cannot
  /// help).
  static final _deterministicServerErrors = [
    RegExp('target language code invalid', caseSensitive: false),
    RegExp('source language code invalid', caseSensitive: false),
    RegExp('engine does not exist', caseSensitive: false),
    RegExp('not supported or implemented', caseSensitive: false),
    RegExp("(?:doesn'?t|does not) support TTS", caseSensitive: false),
  ];

  /// Upstream transport/runtime errors forwarded by Mozhi whose body may echo
  /// the user's text; never classify those as deterministic input errors.
  static final _upstreamFailure = RegExp(
    r'^(?:(?:Post|Get|Put)\s+"|ErrTransport\b|runtime error\b|instance has been rate limited)',
    caseSensitive: false,
  );

  /// Whether retrying against another instance could plausibly succeed.
  ///
  /// True for network errors, timeouts and every status except 400, 413,
  /// 414 and 431 (which any instance would repeat) and Mozhi's deterministic
  /// HTTP 500 validation errors (invalid language code, unknown/disabled
  /// engine, unsupported operation or TTS). Any other 3xx, 4xx or 5xx
  /// (403 challenge pages, 404 parked domains, 401 basic auth, 405, 408,
  /// 429, a redirected POST, transient upstream 500s) comes from that one
  /// instance or its upstream connection.
  bool get isRetryable {
    final code = statusCode;
    if (code == null) return true;
    if (_requestErrors.contains(code)) return false;
    if (code == 500 && _isDeterministicServerError(message)) return false;
    return true;
  }

  static bool _isDeterministicServerError(String message) {
    final trimmed = message.trim();
    if (_upstreamFailure.hasMatch(trimmed)) return false;
    return _deterministicServerErrors.any(
      (pattern) => pattern.hasMatch(trimmed),
    );
  }

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
