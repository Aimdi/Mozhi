import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A request received by [FakeServer].
class RecordedRequest {
  new(this.request, this.body);

  final http.BaseRequest request;

  /// The request body decoded as UTF-8.
  final String body;

  String get method => request.method;
  Uri get url => request.url;

  /// Case-insensitive, like the `http` package's request headers.
  Map<String, String> get headers => request.headers;

  /// The body decoded as JSON.
  Object? get json => jsonDecode(body);

  /// The trigger passed to `http.AbortableRequest`.
  Future<void>? get abortTrigger => switch (request) {
    http.Abortable(:final abortTrigger) => abortTrigger,
    _ => null,
  };
}

/// A scripted response for [FakeServer].
class FakeResponse {
  new(this.body, {this.statusCode = 200, this.reasonPhrase, this.gate});

  /// [text] as UTF-8, split into [chunkSize]-byte chunks (so multi-byte
  /// characters and lines may be cut anywhere).
  factory text(
    String text, {
    int statusCode = 200,
    int chunkSize = 1 << 20,
    String? reasonPhrase,
    Future<void>? gate,
  }) => FakeResponse(
    () => Stream.fromIterable(splitBytes(utf8.encode(text), chunkSize)),
    statusCode: statusCode,
    reasonPhrase: reasonPhrase,
    gate: gate,
  );

  factory json(Object? json, {int statusCode = 200}) =>
      FakeResponse.text(jsonEncode(json), statusCode: statusCode);

  /// Body chunks pushed by the test through [controller].
  factory controlled(
    StreamController<List<int>> controller, {
    int statusCode = 200,
  }) => FakeResponse(() => controller.stream, statusCode: statusCode);

  final Stream<List<int>> Function() body;
  final int statusCode;
  final String? reasonPhrase;

  /// When set, the response headers are only returned once it completes.
  final Future<void>? gate;
}

/// An HTTP server scripted with [FakeResponse]s, served in order.
class FakeServer {
  new([Iterable<FakeResponse> responses = const []])
    : _responses = [...responses];

  final List<FakeResponse> _responses;

  /// Every request received so far.
  final List<RecordedRequest> requests = [];

  late final http.Client client = MockClient.streaming(_handle);

  RecordedRequest get lastRequest => requests.last;

  void enqueue(FakeResponse response) => _responses.add(response);

  Future<http.StreamedResponse> _handle(
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    requests.add(RecordedRequest(request, await body.bytesToString()));
    if (_responses.isEmpty) {
      throw StateError('Unexpected request ${request.method} ${request.url}');
    }
    final response = _responses.removeAt(0);
    await response.gate;
    return http.StreamedResponse(
      response.body(),
      response.statusCode,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

/// [bytes] cut into chunks of [size] bytes.
List<List<int>> splitBytes(List<int> bytes, int size) => [
  for (var start = 0; start < bytes.length; start += size)
    bytes.sublist(start, min(start + size, bytes.length)),
];

/// Chunk sizes used to feed streams with awkward boundaries (mid-line,
/// mid-`\r\n`, mid multi-byte character).
const awkwardChunkSizes = [1, 2, 3, 5, 7, 13, 64, 4096];

/// One SSE event per [data] entry (`data: <json>` + blank line).
String sse(Iterable<Object?> data, {bool crlf = false}) {
  final newline = crlf ? '\r\n' : '\n';
  return [
    for (final item in data)
      'data: ${item is String ? item : jsonEncode(item)}$newline$newline',
  ].join();
}

/// One named SSE event per entry, Anthropic style.
String namedSse(Iterable<(String, Object?)> events) => [
  for (final (name, data) in events)
    'event: $name\ndata: ${jsonEncode(data)}\n\n',
].join();
