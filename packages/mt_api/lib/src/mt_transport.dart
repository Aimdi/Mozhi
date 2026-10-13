import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:mt_api/src/mt_api_exception.dart';

/// Creates the service specific [MtApiException] subclass.
typedef MtExceptionFactory = MtApiException Function(
  String message, {
  required MtErrorKind kind,
  int? statusCode,
  String? detail,
  Uri? uri,
});

/// Maps a non-2xx [http.Response] to an exception.
typedef MtHttpErrorMapper = MtApiException Function(
  http.Response response,
  Uri uri,
);

/// Shared HTTP plumbing for the clients: timeouts, cancellation, UTF-8 JSON
/// decoding and mapping of every failure to an [MtApiException].
@internal
class MtTransport {
  new({
    required this.service,
    required this.timeout,
    required this.newException,
    required this.mapHttpError,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Display name of the service, e.g. `DeepL`.
  final String service;
  final Duration timeout;
  final MtExceptionFactory newException;
  final MtHttpErrorMapper mapHttpError;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// Sends one request and returns the complete 2xx response.
  ///
  /// [json] is encoded as an `application/json` body. Completing
  /// [abortTrigger] aborts the request with [MtErrorKind.cancelled]. The
  /// [timeout] covers sending the request and receiving the whole body.
  Future<http.Response> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? json,
    Future<void>? abortTrigger,
  }) async {
    final abort = Completer<void>();
    var cancelled = false;
    void cancel(Object? _) {
      cancelled = true;
      if (!abort.isCompleted) abort.complete();
    }

    if (abortTrigger != null) {
      unawaited(abortTrigger.then(cancel, onError: cancel));
    }

    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    )..headers.addAll(headers);
    if (json != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(json);
    }

    final http.Response response;
    try {
      response = await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException catch (_, stackTrace) {
      if (!abort.isCompleted) abort.complete();
      Error.throwWithStackTrace(
        newException(
          'No response from ${uri.host} within ${_describe(timeout)}.',
          kind: MtErrorKind.timeout,
          uri: uri,
        ),
        stackTrace,
      );
    } on Exception catch (error, stackTrace) {
      if (cancelled) Error.throwWithStackTrace(_cancelled(uri), stackTrace);
      final detail = switch (error) {
        http.ClientException(:final message) => message,
        _ => error.toString(),
      };
      Error.throwWithStackTrace(
        newException(
          'Could not reach $service at ${uri.host}.',
          kind: MtErrorKind.network,
          detail: detail.isEmpty ? null : detail,
          uri: uri,
        ),
        stackTrace,
      );
    }
    // A client that ignores abort triggers still must not deliver a result
    // the caller has given up on.
    if (cancelled) throw _cancelled(uri);
    final status = response.statusCode;
    if (status < 200 || status > 299) throw mapHttpError(response, uri);
    return response;
  }

  /// Sends a request and decodes the JSON response body.
  Future<Object?> sendJson(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Object? json,
    Future<void>? abortTrigger,
  }) async => decodeJson(
    await send(
      method,
      uri,
      headers: {'accept': 'application/json', ...headers},
      json: json,
      abortTrigger: abortTrigger,
    ),
    uri,
  );

  /// The body as UTF-8 (servers often omit the charset of JSON bodies, so
  /// `Response.body` would fall back to Latin-1).
  static String bodyText(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  Object? decodeJson(http.Response response, Uri uri) {
    try {
      return jsonDecode(bodyText(response));
    } on FormatException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        invalidResponse(uri, 'not valid JSON: ${error.message}'),
        stackTrace,
      );
    }
  }

  Map<String, dynamic> expectObject(Object? json, Uri uri) => switch (json) {
    final Map<String, dynamic> object => object,
    _ => throw invalidResponse(uri, 'expected a JSON object'),
  };

  List<Object?> expectList(Object? json, Uri uri) => switch (json) {
    final List<Object?> list => list,
    _ => throw invalidResponse(uri, 'expected a JSON array'),
  };

  MtApiException invalidResponse(Uri uri, String detail) => newException(
    'Unexpected response from $service.',
    kind: MtErrorKind.invalidResponse,
    detail: detail,
    uri: uri,
  );

  /// The message a server put in an error body: plain text, or the
  /// `message`/`error`/`detail` member of a JSON object (`message` and
  /// `detail` are combined when both are present). HTML error pages from
  /// reverse proxies are ignored.
  static String? serverMessage(http.Response response) {
    final body = bodyText(response).trim();
    final contentType = response.headers['content-type'] ?? '';
    if (body.isEmpty || body.startsWith('<') || contentType.contains('html')) {
      return null;
    }
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return body;
    }
    if (json is String) return _nonEmpty(json);
    if (json is! Map) return null;
    final message = _text(json['message']) ?? _text(json['error']);
    final detail = _text(json['detail']);
    return switch ((message, detail)) {
      (final String m, final String d) when m != d => '$m: $d',
      (final String m, _) => m,
      (_, final String d) => d,
      _ => null,
    };
  }

  static String? _text(Object? value) => switch (value) {
    final String text => _nonEmpty(text),
    final Map<dynamic, dynamic> nested => _text(nested['message']),
    _ => null,
  };

  static String? _nonEmpty(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  MtApiException _cancelled(Uri uri) => newException(
    'The request was cancelled.',
    kind: MtErrorKind.cancelled,
    uri: uri,
  );

  static String _describe(Duration duration) =>
      duration.inMilliseconds % 1000 == 0
      ? '${duration.inSeconds} s'
      : '${duration.inMilliseconds} ms';

  /// Closes the underlying client if this transport created it.
  void close() {
    if (_ownsClient) _httpClient.close();
  }
}
