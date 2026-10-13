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

  /// Whether retrying against another instance could plausibly succeed
  /// (network errors, timeouts, 429 and 5xx responses).
  bool get isRetryable =>
      statusCode == null || statusCode == 429 || statusCode! >= 500;

  @override
  String toString() =>
      'MozhiApiException(${statusCode ?? 'network'}): $message'
      '${uri == null ? '' : ' [$uri]'}';
}
