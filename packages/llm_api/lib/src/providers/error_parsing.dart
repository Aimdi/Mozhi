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
/// [reasonPhrase].
LlmApiException httpError(int statusCode, String body, String? reasonPhrase) {
  final trimmed = body.trim();
  final reason = reasonPhrase?.trim() ?? '';
  final plainText = trimmed.isEmpty || trimmed.startsWith('<')
      ? null
      : truncate(trimmed, maxPlainErrorMessageLength);
  final message =
      errorMessageFromJson(tryDecodeJson(trimmed)) ??
      plainText ??
      (reason.isNotEmpty ? reason : 'HTTP $statusCode');
  return LlmApiException(
    message,
    statusCode: statusCode,
    body: trimmed.isEmpty ? null : truncate(body, maxErrorBodyLength),
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
