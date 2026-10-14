import 'package:meta/meta.dart';

/// What went wrong with a machine translation request, independent of the
/// service. Lets the app pick a localised message instead of showing the
/// English [MtApiException.message].
enum MtErrorKind {
  /// DNS, TLS, connection refused/reset, CORS rejection on the web.
  network,

  /// No complete response within the client's timeout.
  timeout,

  /// The caller completed the request's `abortTrigger`.
  cancelled,

  /// A 2xx response whose body is not what the API documents.
  invalidResponse,

  /// HTTP 400 (unsupported language pair, invalid parameter, ...).
  badRequest,

  /// HTTP 401/403, or a server that requires an API key.
  unauthorized,

  /// HTTP 404 (unknown glossary, wrong base URL).
  notFound,

  /// HTTP 413/414, or more text than the server accepts.
  payloadTooLarge,

  /// HTTP 429 (and DeepL's 529).
  rateLimited,

  /// DeepL's HTTP 456: the billing period's character quota is used up.
  quotaExceeded,

  /// HTTP 5xx.
  server,

  /// Any other non-2xx status.
  unknown;

  /// The kind for a non-2xx HTTP [statusCode].
  static MtErrorKind fromStatus(int statusCode) => switch (statusCode) {
    400 => badRequest,
    401 || 403 => unauthorized,
    404 => notFound,
    413 || 414 => payloadTooLarge,
    429 || 529 => rateLimited,
    456 => quotaExceeded,
    >= 500 && < 600 => server,
    _ => unknown,
  };
}

/// Base class of every error thrown by the clients in this package.
///
/// [message] is a short, user-presentable English sentence; [detail] is the
/// raw message the server sent (if any). [statusCode] is `null` for
/// transport failures, timeouts, cancellations and malformed bodies.
class MtApiException implements Exception {
  const new(
    this.message, {
    this.kind = MtErrorKind.unknown,
    this.statusCode,
    this.detail,
    this.uri,
  });

  final String message;
  final MtErrorKind kind;
  final int? statusCode;
  final String? detail;
  final Uri? uri;

  /// Whether the same request could plausibly succeed later (network
  /// errors, timeouts, rate limiting and 5xx responses).
  bool get isRetryable => switch (kind) {
    MtErrorKind.network ||
    MtErrorKind.timeout ||
    MtErrorKind.rateLimited ||
    MtErrorKind.server => true,
    _ => false,
  };

  /// [message] followed by the server's [detail] when it adds information.
  String get fullMessage {
    final extra = detail?.trim() ?? '';
    if (extra.isEmpty || message.contains(extra)) return message;
    return '$message ($extra)';
  }

  /// Name used by [toString].
  @protected
  String get typeName => 'MtApiException';

  /// Includes [uri] without user info and query, so credentials and text
  /// never reach logs.
  @override
  String toString() =>
      '$typeName(${statusCode ?? kind.name}): $fullMessage'
      '${uri == null ? '' : ' [${redactUri(uri!)}]'}';

  /// [uri] without user info, query and fragment.
  static Uri redactUri(Uri uri) => Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  );
}

/// Thrown by `DeeplClient`.
class DeeplApiException extends MtApiException {
  const new(
    super.message, {
    super.kind,
    super.statusCode,
    super.detail,
    super.uri,
  });

  @override
  String get typeName => 'DeeplApiException';
}

/// Thrown by `LibreTranslateClient`.
class LibreTranslateException extends MtApiException {
  const new(
    super.message, {
    super.kind,
    super.statusCode,
    super.detail,
    super.uri,
  });

  @override
  String get typeName => 'LibreTranslateException';
}
