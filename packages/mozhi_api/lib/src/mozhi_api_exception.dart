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
  /// 414 and 431, which any instance would repeat. Mozhi reports engine failures, including an
  /// unsupported language, as 500; any other 3xx or 4xx (403 challenge
  /// pages, 404 parked domains, 401 basic auth, 405, 408, 429, a redirected
  /// POST) comes from whatever sits in front of that one instance.
  bool get isRetryable =>
      statusCode == null || !_requestErrors.contains(statusCode);

  /// Includes [uri] without any user info, so credentials never reach logs.
  @override
  String toString() {
    final shown = switch (uri) {
      final uri? when uri.userInfo.isNotEmpty => uri.replace(userInfo: ''),
      final uri => uri,
    };
    return 'MozhiApiException(${statusCode ?? 'network'}): $message'
        '${shown == null ? '' : ' [$shown]'}';
  }
}
