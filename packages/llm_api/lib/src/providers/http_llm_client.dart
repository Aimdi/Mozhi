import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:llm_api/src/llm_client.dart';
import 'package:llm_api/src/llm_exception.dart';
import 'package:llm_api/src/models.dart';
import 'package:llm_api/src/providers/error_parsing.dart';
import 'package:llm_api/src/retry_policy.dart';
import 'package:llm_api/src/streaming/sse_decoder.dart';
import 'package:meta/meta.dart';

/// Transport shared by the provider clients: URL building, request sending
/// with timeouts, cancellation, retries and error mapping.
///
/// Subclasses implement [streamChat] with [abortableStream] and
/// [listModels] with [getJson].
abstract class HttpLlmClient implements LlmClient {
  /// Uses [httpClient] when given (it is then not closed by [close]),
  /// otherwise creates and owns a new `http.Client`.
  new(
    this.endpoint, {
    http.Client? httpClient,
    this.timeout = LlmClient.defaultTimeout,
    this.retryPolicy = LlmRetryPolicy.standard,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  @override
  final LlmEndpoint endpoint;

  @override
  final Duration timeout;

  /// When [streamChat] sends a request again after a transient failure (see
  /// [abortableStream]); [LlmRetryPolicy.none] turns retries off.
  final LlmRetryPolicy retryPolicy;

  final http.Client _httpClient;
  final bool _ownsClient;

  /// The configured API key without surrounding whitespace, or null when
  /// none is set.
  @protected
  String? get apiKey {
    final key = endpoint.apiKey?.trim();
    return key == null || key.isEmpty ? null : key;
  }

  @override
  Future<String> chat(LlmRequest request) => streamChat(request).join();

  /// Nothing to warm up: answers false. Overridden by local providers.
  @override
  Future<bool> warmUp(String model) async => false;

  @override
  void close() {
    if (_ownsClient) _httpClient.close();
  }

  /// [LlmEndpoint.baseUrl] with [path] appended and [query] merged into any
  /// query the base URL already has.
  @protected
  Uri resolve(String path, [Map<String, String> query = const {}]) {
    final base = endpoint.baseUrl;
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final parameters = {...base.queryParameters, ...query};
    return base.replace(
      path: '$basePath/$path',
      queryParameters: parameters.isEmpty ? null : parameters,
    );
  }

  /// Sends a request and returns the streamed response once a 2xx status
  /// arrives.
  ///
  /// [json] is encoded as the request body. [LlmEndpoint.headers] are added
  /// after [headers]. Completing [abortTrigger] aborts the request. Throws
  /// [LlmApiException] when no response headers arrive within [timeout] or
  /// the status is not 2xx (with the message extracted from the body).
  ///
  /// Redirects are never followed: dart:io copies every header except
  /// `Authorization` / `Cookie` to the new host, which would leak
  /// `x-api-key`, `x-goog-api-key` and custom auth headers. A 3xx answer
  /// throws [LlmApiException] (`Redirected to <host> — update the base URL`,
  /// [LlmApiException.isRedirect]); on the web the browser reports a
  /// redirect as a network error instead.
  @protected
  Future<http.StreamedResponse> send(
    String method,
    Uri url, {
    required Future<void> abortTrigger,
    Map<String, String> headers = const {},
    Object? json,
  }) async {
    final request =
        http.AbortableRequest(method, url, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..maxRedirects = 0;
    request.headers
      ..addAll(headers)
      ..addAll(endpoint.headers);
    if (json != null) request.body = jsonEncode(json);

    final http.StreamedResponse response;
    try {
      response = await _httpClient.send(request).timeout(timeout);
    } on TimeoutException {
      throw LlmApiException(
        'No response from ${url.host} within ${_describe(timeout)}.',
      );
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) return response;
    if (status >= 300 && status < 400) {
      // Release the connection; the body of a redirect is of no use.
      unawaited(response.stream.listen(null).cancel());
      throw redirectError(url, status, _header(response.headers, 'location'));
    }

    String body;
    try {
      body = await readText(response);
    } on Object {
      body = '';
    }
    throw httpError(
      status,
      body,
      response.reasonPhrase,
      headers: response.headers,
    );
  }

  /// The response body as text, decoded incrementally (multi-byte
  /// characters may be split across chunks). Errors with a
  /// [TimeoutException] when no chunk arrives for [timeout].
  @protected
  Stream<String> responseText(http.StreamedResponse response) => response.stream
      .timeout(timeout)
      .transform(const Utf8Decoder(allowMalformed: true));

  /// The whole response body as text (see [responseText]).
  @protected
  Future<String> readText(http.StreamedResponse response) =>
      responseText(response).join();

  /// The response body decoded as server-sent events.
  @protected
  Stream<SseEvent> sseEvents(http.StreamedResponse response) =>
      responseText(response).transform(const SseDecoder());

  /// `GET`s [url] and decodes the JSON response. Errors are thrown as
  /// [LlmApiException].
  @protected
  Future<Object?> getJson(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    // Completed when done so that a timed out request is aborted.
    final abort = Completer<void>();
    try {
      final response = await send(
        'GET',
        url,
        headers: headers,
        abortTrigger: abort.future,
      );
      return jsonDecode(await readText(response));
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(toLlmException(error), stackTrace);
    } finally {
      abort.complete();
    }
  }

  /// Wraps the text stream produced by [open] so that it starts when listened
  /// to and can be cancelled at any time.
  ///
  /// [open] receives the abort trigger to pass to [send]. It is completed
  /// when the returned stream's subscription is cancelled, which aborts the
  /// request whether it is still connecting or already streaming, when the
  /// request failed, and when the stream ends (a no-op for finished
  /// requests). The first error ends the stream and is delivered as
  /// [LlmApiException] (see [toLlmException]).
  ///
  /// A transient failure ([LlmApiException.isTransient]) that happens before
  /// the first text delta was delivered calls [open] again after the wait
  /// of [retryPolicy] (see [LlmRetryPolicy.delayBefore]), as often as it
  /// allows. Once a delta has been delivered nothing is retried, so the
  /// user never pays twice for output they saw. Cancelling during the wait
  /// ends it at once, without another request.
  @protected
  Stream<String> abortableStream(
    Future<Stream<String>> Function(Future<void> abortTrigger) open,
  ) {
    // Completed when the subscription is cancelled (or the stream ended).
    final stopped = Completer<void>();
    // The abort trigger of the current attempt.
    var abort = Completer<void>();
    StreamSubscription<String>? subscription;
    late final StreamController<String> controller;
    var delivered = false;
    var retries = 0;

    void complete(Completer<void> completer) {
      if (!completer.isCompleted) completer.complete();
    }

    late final Future<void> Function() start;

    Future<void> failOrRetry(Object error, StackTrace stackTrace) async {
      complete(abort);
      if (stopped.isCompleted || controller.isClosed) return;
      final exception = toLlmException(error);
      final wait = delivered
          ? null
          : retryPolicy.delayBefore(retries + 1, exception);
      if (wait == null) {
        controller.addError(exception, stackTrace);
        unawaited(controller.close());
        return;
      }
      retries++;
      await _sleep(wait, stopped.future);
      if (stopped.isCompleted) return;
      abort = Completer<void>();
      await start();
    }

    start = () async {
      final Stream<String> output;
      try {
        output = await open(abort.future);
      } on Object catch (error, stackTrace) {
        await failOrRetry(error, stackTrace);
        return;
      }
      if (stopped.isCompleted) {
        // Cancelled while connecting: release the response right away
        // (clients that support aborting have already done so).
        unawaited(output.listen(null).cancel());
        return;
      }
      subscription = output.listen(
        (delta) {
          delivered = true;
          controller.add(delta);
        },
        onError: (Object error, StackTrace stackTrace) {
          subscription = null;
          unawaited(failOrRetry(error, stackTrace));
        },
        onDone: () => unawaited(controller.close()),
        cancelOnError: true,
      );
      if (controller.isPaused) subscription?.pause();
    };

    controller = StreamController<String>(
      onListen: () => unawaited(start()),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        complete(stopped);
        complete(abort);
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// Completes after [duration], or as soon as [stop] completes.
  static Future<void> _sleep(Duration duration, Future<void> stop) {
    final done = Completer<void>();
    void wake() {
      if (!done.isCompleted) done.complete();
    }

    final timer = Timer(duration, wake);
    unawaited(
      stop.then((_) {
        timer.cancel();
        wake();
      }),
    );
    return done.future;
  }

  /// Transport error messages (of `dart:io`, Cronet and the like) that mean
  /// an established or half-open connection was lost, as opposed to one
  /// that could not be made (refused, failed DNS lookup, TLS errors) or a
  /// request the app's network policy refused.
  static final _droppedConnection = RegExp(
    'connection (?:closed|reset|abort|terminated)|reset by peer|broken pipe|'
    'software caused connection abort|err_connection_(?:reset|closed|aborted)'
    '|err_network_changed|err_empty_response|err_http2|err_quic|'
    'stream (?:was )?reset|unexpected end of stream',
    caseSensitive: false,
  );

  /// Maps any failure to [LlmApiException] and makes sure the API key does
  /// not appear in it. A transport error that means the connection was lost
  /// is marked [LlmApiException.connectionDropped].
  @protected
  LlmApiException toLlmException(Object error) {
    final exception = switch (error) {
      LlmApiException() => error,
      TimeoutException() => LlmApiException(
        'The server stopped responding (no data for ${_describe(timeout)}).',
      ),
      http.ClientException(:final message) => LlmApiException(
        'Could not reach ${endpoint.baseUrl.host}: $message',
        connectionDropped: _droppedConnection.hasMatch(message),
      ),
      FormatException(:final message, :final source) => LlmApiException(
        'The server sent malformed data: $message',
        body: source is String ? truncate(source, maxErrorBodyLength) : null,
      ),
      _ => LlmApiException('Unexpected error: $error'),
    };
    return _redact(exception);
  }

  /// [models] without duplicate ids, sorted by id.
  @protected
  List<LlmModel> sortedModels(Iterable<LlmModel> models) {
    final byId = {for (final model in models) model.id: model};
    return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  /// [exception] with every occurrence of the API key replaced.
  LlmApiException _redact(LlmApiException exception) {
    final key = apiKey;
    final category = switch (exception) {
      LlmRefusalException(:final category) => category,
      _ => null,
    };
    final texts = [exception.message, exception.body, category];
    if (key == null || !texts.any((text) => text?.contains(key) ?? false)) {
      return exception;
    }
    const redacted = '[redacted]';
    final message = exception.message.replaceAll(key, redacted);
    return switch (exception) {
      LlmRefusalException() => LlmRefusalException(
        message,
        category: category?.replaceAll(key, redacted),
      ),
      LlmTruncatedException(:final partialText, :final reason) =>
        LlmTruncatedException(
          message: message,
          partialText: partialText,
          reason: reason,
        ),
      LlmInterruptedException(:final partialText) => LlmInterruptedException(
        message: message,
        partialText: partialText,
      ),
      _ => LlmApiException(
        message,
        statusCode: exception.statusCode,
        body: exception.body?.replaceAll(key, redacted),
        retryAfter: exception.retryAfter,
        connectionDropped: exception.connectionDropped,
      ),
    };
  }

  /// The value of the header [name] (lower case) in [headers], whose names
  /// may use any case.
  static String? _header(Map<String, String> headers, String name) {
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key.toLowerCase() == name) return value;
    }
    return null;
  }

  static String _describe(Duration duration) =>
      duration.inMilliseconds % 1000 == 0
      ? '${duration.inSeconds} s'
      : '${duration.inMilliseconds} ms';
}

/// The non-blank system messages of [messages] joined with blank lines, for
/// APIs that take the system prompt separately from the conversation.
String joinSystemMessages(Iterable<LlmMessage> messages) => [
  for (final message in messages)
    if (message.role == LlmRole.system && message.content.trim().isNotEmpty)
      message.content,
].join('\n\n');
