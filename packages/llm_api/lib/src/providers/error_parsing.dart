import 'dart:convert';

import 'package:llm_api/src/llm_exception.dart';

/// Maximum length of [LlmApiException.body].
const maxErrorBodyLength = 2000;

/// Maximum length of a message taken verbatim from a non-JSON error body.
const maxPlainErrorMessageLength = 300;

/// Extracts a human readable message from a decoded JSON error body.
///
/// Looks at `error.message`, `error` (a string), `message` and `detail` (a
/// string, or a FastAPI style list of `{"msg": ...}` entries), in that
/// order. A top-level list (Gemini without `alt=sse`) is searched through
/// its first element. Returns null when none is present.
String? errorMessageFromJson(Object? json) {
  final message = switch (json) {
    {'error': {'message': final String message}} => message,
    {'error': final String message} => message,
    {'message': final String message} => message,
    {'detail': final String message} => message,
    {'detail': [{'msg': final String message}, ...]} => message,
    [final first, ...] => errorMessageFromJson(first),
    _ => null,
  }?.trim();
  return message == null || message.isEmpty ? null : message;
}

/// Builds the exception for an HTTP response with a non-2xx [statusCode].
///
/// The message comes from the JSON error body (see [errorMessageFromJson]),
/// else from the trimmed plain-text body (at most 300 characters; HTML error
/// pages are skipped in favour of the reason phrase), else from
/// [reasonPhrase]. [LlmApiException.retryAfter] comes from the response
/// [headers] or the body (see [retryAfterFrom]).
LlmApiException httpError(
  int statusCode,
  String body,
  String? reasonPhrase, {
  Map<String, String> headers = const {},
  DateTime Function() now = DateTime.now,
}) {
  final trimmed = body.trim();
  final reason = reasonPhrase?.trim() ?? '';
  final plainText = trimmed.isEmpty || trimmed.startsWith('<')
      ? null
      : truncate(trimmed, maxPlainErrorMessageLength);
  final json = tryDecodeJson(trimmed);
  final message =
      errorMessageFromJson(json) ??
      plainText ??
      (reason.isNotEmpty ? reason : 'HTTP $statusCode');
  return LlmApiException(
    message,
    statusCode: statusCode,
    body: trimmed.isEmpty ? null : truncate(body, maxErrorBodyLength),
    retryAfter: retryAfterFrom(headers, json, now: now),
  );
}

/// How long a server asked to wait before the next request, or null when
/// it did not say.
///
/// Looks at, in this order: the `retry-after-ms` header (milliseconds, sent
/// by OpenAI), the `Retry-After` header (seconds, or an HTTP date compared
/// with [now]) and a Gemini `RetryInfo` entry of `error.details` in the
/// decoded JSON body (`"retryDelay": "13s"`). Header names may use any
/// case; negative waits count as zero.
Duration? retryAfterFrom(
  Map<String, String> headers,
  Object? json, {
  DateTime Function() now = DateTime.now,
}) {
  String? header(String name) {
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key.toLowerCase() == name) return value.trim();
    }
    return null;
  }

  Duration? seconds(String? text, {int scale = 1000000}) {
    final value = text == null ? null : double.tryParse(text);
    if (value == null || value.isNaN || value.isInfinite) return null;
    return Duration(microseconds: (value * scale).clamp(0, _maxWait).round());
  }

  if (seconds(header('retry-after-ms'), scale: 1000) case final wait?) {
    return wait;
  }
  final retryAfter = header('retry-after');
  if (seconds(retryAfter) case final wait?) return wait;
  if (_parseHttpDate(retryAfter) case final date?) {
    final wait = date.difference(now());
    return wait.isNegative ? Duration.zero : wait;
  }
  if (json case {'error': {'details': final List<Object?> details}}) {
    for (final detail in details) {
      if (detail case {'retryDelay': final String delay}
          when delay.endsWith('s')) {
        if (seconds(delay.substring(0, delay.length - 1)) case final wait?) {
          return wait;
        }
      }
    }
  }
  return null;
}

/// A day, in microseconds: longer waits are capped (they are never
/// honoured anyway).
const _maxWait = 86400000000;

/// The IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) of [text] in UTC, or
/// null when [text] is not one.
DateTime? _parseHttpDate(String? text) {
  if (text == null) return null;
  final match = _httpDate.firstMatch(text);
  if (match == null) return null;
  final month = _months.indexOf(match[2]!.toLowerCase()) + 1;
  if (month == 0) return null;
  return DateTime.utc(
    int.parse(match[3]!),
    month,
    int.parse(match[1]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}

final _httpDate = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// Builds the exception for a redirect (3xx) answer to a request for [url].
///
/// Redirects are never followed because most HTTP stacks copy custom auth
/// headers (`x-api-key`, `x-goog-api-key`, `LlmEndpoint.headers`) to the
/// new host. The message names where the server pointed, taken from the
/// [location] header (resolved against [url]): its host when that differs
/// from [url]'s, otherwise the new URL without query (e.g. an `http` to
/// `https` upgrade or a path with a trailing slash), so that the user can
/// fix the base URL.
LlmApiException redirectError(Uri url, int statusCode, String? location) {
  final reference = location?.trim() ?? '';
  final parsed = reference.isEmpty ? null : Uri.tryParse(reference);
  final target = parsed == null ? null : url.resolveUri(parsed);
  final destination = switch (target) {
    null || Uri(host: '') => 'another address',
    Uri(:final host) when host != url.host => host,
    final Uri target => Uri(
      scheme: target.scheme,
      host: target.host,
      port: target.hasPort ? target.port : null,
      path: target.path,
    ).toString(),
  };
  return LlmApiException(
    'Redirected to $destination — update the base URL',
    statusCode: statusCode,
  );
}

/// Builds the exception for an error object received inside a successful
/// response stream (e.g. `{"error": {"code": 502, "message": "..."}}`).
///
/// [LlmApiException.statusCode] is taken from an integer `error.code` when
/// present.
LlmApiException streamError(Object? json, String raw) => LlmApiException(
  errorMessageFromJson(json) ?? 'The server reported an error.',
  statusCode: switch (json) {
    {'error': {'code': final int code}} => code,
    _ => null,
  },
  body: truncate(raw, maxErrorBodyLength),
);

/// Decodes [text] as JSON, returning null when it is not valid JSON.
Object? tryDecodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// Shortens [text] to at most [maxLength] characters, marking a cut with an
/// ellipsis.
String truncate(String text, int maxLength) =>
    text.length <= maxLength ? text : '${text.substring(0, maxLength - 1)}…';
