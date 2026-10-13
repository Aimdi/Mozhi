import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';

/// A JSON response encoded as UTF-8 *without* a charset in the content
/// type, like many servers send it.
http.Response jsonResponse(Object? body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(body is String ? body : jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

http.Response textResponse(
  String body,
  int status, {
  Map<String, String> headers = const {},
}) => http.Response.bytes(utf8.encode(body), status, headers: headers);

/// A `MockClient` that records every request and answers with [handler].
class RecordingClient extends http.BaseClient {
  RecordingClient(FutureOr<http.Response> Function(http.Request) handler) {
    _inner = MockClient((request) async {
      requests.add(request);
      return await handler(request);
    });
  }

  late final http.Client _inner;
  final List<http.Request> requests = [];

  http.Request get single => requests.single;

  Object? get singleJsonBody => jsonDecode(single.body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);
}

/// A client whose requests never complete unless aborted, and which honours
/// abort triggers like the real IO and browser clients.
class HangingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  bool sawAbort = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    if (trigger == null) {
      return await Completer<http.StreamedResponse>().future;
    }
    await trigger;
    sawAbort = true;
    throw http.RequestAbortedException(request.url);
  }
}

Matcher throwsMtError<T extends MtApiException>({
  required MtErrorKind kind,
  Object? statusCode = anything,
  Object message = anything,
  Object? detail = anything,
  Object uri = anything,
}) => throwsA(
  isA<T>()
      .having((e) => e.kind, 'kind', kind)
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having((e) => e.message, 'message', message)
      .having((e) => e.detail, 'detail', detail)
      .having((e) => e.uri, 'uri', uri),
);
