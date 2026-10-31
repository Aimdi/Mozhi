import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';

/// A response that knows its final URL, like `dart:io`'s.
class _ResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  new(
    super.stream,
    super.statusCode, {
    required this.url,
    super.request,
    super.headers,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}

/// A client whose answers know their final URL ([finalUrl]).
class _RedirectingClient extends http.BaseClient {
  new(this.finalUrl);

  final Uri finalUrl;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      _ResponseWithUrl(
        Stream.value(utf8.encode('moved')),
        200,
        url: finalUrl,
        request: request,
        headers: const {'x': 'y'},
        reasonPhrase: 'OK',
      );

  @override
  void close() => closed = true;
}

/// A client that fails with [error] from send.
class _ThrowingClient extends http.BaseClient {
  new(this.error);

  final Object error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(error);
}

void main() {
  late EgressLedger ledger;

  setUp(() => ledger = EgressLedger());

  EgressEntry single() => ledger.entries.single;

  test('records a request and its answer without its address', () async {
    final client = EgressRecordingClient(
      MockClient((request) async => http.Response('{"ok":true}', 200)),
      ledger: ledger,
      viaProxy: (host) => host == 'mozhi.example',
    );

    final response = await client.post(
      Uri.parse('https://user:pw@mozhi.example/api/translate?secret=1'),
      body: 'hola mundo',
    );

    expect(response.body, '{"ok":true}');
    final entry = single();
    expect(entry.method, 'POST');
    expect(entry.scheme, 'https');
    expect(entry.destination.host, 'mozhi.example');
    expect(entry.destination.kind, EgressDestinationKind.publicServer);
    expect(entry.purpose, EgressPurpose.translation);
    expect(entry.viaProxy, isTrue);
    // Body (10) + path (14) + '?' + query (8).
    expect(entry.bytesSent, 10 + 14 + 1 + 8);
    expect(entry.bytesReceived, 11);
    expect(entry.statusCode, 200);
    expect(entry.outcome, EgressOutcome.succeeded);
    expect(entry.duration, isNotNull);
    // Nothing of the address but the host is kept.
    final kept = jsonEncode(entry.toMap());
    expect(kept, isNot(contains('hola')));
    expect(kept, isNot(contains('secret')));
    expect(kept, isNot(contains('api/translate')));
    expect(kept, isNot(contains('pw')));
  });

  test('a GET without a known body size counts its address', () async {
    final client = EgressRecordingClient(
      MockClient.streaming(
        (request, body) async => http.StreamedResponse(Stream.value([1]), 200),
      ),
      ledger: ledger,
    );
    final request = http.StreamedRequest(
      'GET',
      Uri.parse('https://mozhi.example/api/tts?text=hi'),
    );
    unawaited(request.sink.close());
    final response = await client.send(request);
    await response.stream.drain<void>();

    expect(single().bytesSent, '/api/tts'.length + 1 + 'text=hi'.length);
    expect(single().purpose, EgressPurpose.speech);
    expect(single().method, 'GET');
  });

  test('an unknown body size of other methods is unknown', () {
    final request = http.StreamedRequest('PUT', Uri.parse('https://a.example'));
    expect(EgressRecordingClient.bytesSentOf(request), isNull);
  });

  test('records server errors', () async {
    final client = EgressRecordingClient(
      MockClient((request) async => http.Response('no', 401)),
      ledger: ledger,
    );
    await client.get(Uri.parse('https://api.openai.com/v1/models'));
    expect(single().outcome, EgressOutcome.httpError);
    expect(single().statusCode, 401);
    expect(single().destination.name, 'OpenAI');
    expect(single().purpose, EgressPurpose.catalog);
  });

  test('uses the given purpose and names unusual methods OTHER', () async {
    final client = EgressRecordingClient(
      MockClient((request) async => http.Response('', 204)),
      ledger: ledger,
      purpose: EgressPurpose.webPage,
    );
    await client.send(http.Request('LOCK', Uri.parse('https://a.example')));
    expect(single().method, 'OTHER');
    expect(single().purpose, EgressPurpose.webPage);
    expect(single().destination.kind, EgressDestinationKind.website);
    expect(single().viaProxy, isFalse);
  });

  group('failures', () {
    Future<EgressEntry> failWith(Object error) async {
      final client = EgressRecordingClient(
        _ThrowingClient(error),
        ledger: ledger,
      );
      await expectLater(
        client.get(Uri.parse('https://mozhi.example/api/engines')),
        throwsA(same(error)),
      );
      return ledger.entries.last;
    }

    test('a refused proxy setting sent nothing', () async {
      final entry = await failWith(InvalidProxyException(null));
      expect(entry.outcome, EgressOutcome.notSent);
      expect(entry.failure, isNull);
    });

    test('an aborted request was cancelled', () async {
      final entry = await failWith(http.RequestAbortedException());
      expect(entry.outcome, EgressOutcome.cancelled);
    });

    test('timeouts, connection and TLS errors', () async {
      expect(
        (await failWith(TimeoutException('slow'))).failure,
        EgressFailure.timeout,
      );
    });

    test('connection errors', () async {
      final entry = await failWith(const SocketException('refused'));
      expect(entry.outcome, EgressOutcome.failed);
      expect(entry.failure, EgressFailure.connection);
    });

    test('secure connection errors', () async {
      expect(
        (await failWith(const HandshakeException('bad cert'))).failure,
        EgressFailure.secureConnection,
      );
    });

    test('other client errors count as connection errors', () async {
      expect(
        (await failWith(http.ClientException('gone'))).failure,
        EgressFailure.connection,
      );
      expect(
        (await failWith(const HttpException('broken'))).failure,
        EgressFailure.connection,
      );
    });

    test('anything else', () async {
      expect((await failWith(StateError('?'))).failure, EgressFailure.other);
    });
  });

  group('the answer', () {
    test('an error while streaming fails the request', () async {
      final controller = StreamController<List<int>>();
      final client = EgressRecordingClient(
        MockClient.streaming(
          (request, body) async =>
              http.StreamedResponse(controller.stream, 200),
        ),
        ledger: ledger,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://mozhi.example/api/engines')),
      );
      final body = response.stream.toList();
      controller
        ..add([1, 2, 3])
        ..addError(const SocketException('reset'));
      await expectLater(body, throwsA(isA<SocketException>()));
      await controller.close();

      final entry = single();
      expect(entry.outcome, EgressOutcome.failed);
      expect(entry.failure, EgressFailure.connection);
      expect(entry.bytesReceived, 3);
    });

    test('an aborted answer was cancelled', () async {
      final client = EgressRecordingClient(
        MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            Stream<List<int>>.error(http.RequestAbortedException()),
            200,
          ),
        ),
        ledger: ledger,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://a.example')),
      );
      await expectLater(response.stream.toList(), throwsA(anything));
      expect(single().outcome, EgressOutcome.cancelled);
    });

    test('a broken proxy while streaming is a failure', () async {
      final client = EgressRecordingClient(
        MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            Stream<List<int>>.error(InvalidProxyException(null)),
            200,
          ),
        ),
        ledger: ledger,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://a.example')),
      );
      await expectLater(response.stream.toList(), throwsA(anything));
      expect(single().outcome, EgressOutcome.failed);
    });

    test('stopping to read cancels the request', () async {
      final controller = StreamController<List<int>>();
      final client = EgressRecordingClient(
        MockClient.streaming(
          (request, body) async =>
              http.StreamedResponse(controller.stream, 200),
        ),
        ledger: ledger,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://a.example')),
      );
      expect(single().statusCode, 200);
      expect(single().isPending, isTrue);
      final subscription = response.stream.listen((_) {});
      controller.add([1, 2]);
      await pumpEventQueue();
      subscription
        ..pause()
        ..resume();
      await subscription.cancel();

      expect(single().outcome, EgressOutcome.cancelled);
      expect(single().bytesReceived, 2);
      await controller.close();
    });

    test('keeps the final URL and notes a redirect to another host', () async {
      final inner = _RedirectingClient(
        Uri.parse('https://objects.githubusercontent.com/x'),
      );
      final client = EgressRecordingClient(inner, ledger: ledger);
      final response = await client.send(
        http.Request('GET', Uri.parse('https://github.com/a/b.traineddata')),
      );

      expect(response, isA<http.BaseResponseWithUrl>());
      expect(
        (response as http.BaseResponseWithUrl).url.host,
        'objects.githubusercontent.com',
      );
      expect(response.headers, {'x': 'y'});
      expect(response.reasonPhrase, 'OK');
      expect(await response.stream.bytesToString(), 'moved');
      expect(single().redirectedTo, 'objects.githubusercontent.com');
      expect(single().purpose, EgressPurpose.modelDownload);
      expect(single().destination.name, 'GitHub');

      client.close();
      expect(inner.closed, isTrue);
    });

    test('a final URL on the same host is no redirect', () async {
      final client = EgressRecordingClient(
        _RedirectingClient(Uri.parse('https://github.com/b')),
        ledger: ledger,
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://github.com/a')),
      );
      await response.stream.drain<void>();
      expect(single().redirectedTo, isNull);
    });
  });

  test("names WebDAV's PROPFIND and MKCOL", () async {
    final client = EgressRecordingClient(
      MockClient((request) async => http.Response('', 207)),
      ledger: ledger,
    );
    for (final method in ['PROPFIND', 'MKCOL']) {
      await client.send(http.Request(method, Uri.parse('https://a.example')));
    }
    expect(ledger.entries.map((e) => e.method), ['PROPFIND', 'MKCOL']);
  });

  group('a purpose marked on the request', () {
    test(
      'overrides the guess and the client purpose, and is not sent',
      () async {
        final sent = <http.BaseRequest>[];
        final client = EgressRecordingClient(
          MockClient((request) async {
            sent.add(request);
            return http.Response('', 200);
          }),
          ledger: ledger,
          purpose: EgressPurpose.webPage,
        );
        await EgressPurposeClient(
          client,
          purpose: EgressPurpose.sync,
        ).get(Uri.parse('https://cloud.example/dav/f.mozhibackup'));
        expect(single().purpose, EgressPurpose.sync);
        expect(single().carriedContent, isFalse);
        expect(
          sent.single.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains(EgressRecordingClient.purposeHeader)),
        );
      },
    );

    test('an unknown mark is ignored (and removed)', () async {
      final sent = <http.BaseRequest>[];
      final client = EgressRecordingClient(
        MockClient((request) async {
          sent.add(request);
          return http.Response('', 200);
        }),
        ledger: ledger,
      );
      final request = http.Request('GET', Uri.parse('https://a.example/x'))
        ..headers['X-Mozhi-Egress-Purpose'] = 'nonsense';
      await client.send(request);
      expect(single().purpose, EgressPurpose.other);
      expect(sent.single.headers, isEmpty);
    });

    test('EgressPurposeClient leaves the shared client open', () {
      final inner = _RedirectingClient(Uri.parse('https://a.example'));
      EgressPurposeClient(inner, purpose: EgressPurpose.sync).close();
      expect(inner.closed, isFalse);
    });
  });

  test('close leaves the inner client open when asked to', () {
    final inner = _RedirectingClient(Uri.parse('https://a.example'));
    EgressRecordingClient(inner, ledger: ledger, closesInner: false).close();
    expect(inner.closed, isFalse);
  });

  group('engineOf', () {
    EgressRecordingClient recording() => EgressRecordingClient(
      MockClient((request) async => http.Response('{}', 200)),
      ledger: ledger,
    );

    test("records the Mozhi engine of a translation's form body", () async {
      await recording().post(
        Uri.parse('https://mozhi.example/api/translate'),
        body: {
          'engine': 'duckduckgo',
          'from': 'de',
          'to': 'en',
          'text': 'secret words',
        },
      );
      final entry = single();
      expect(entry.engine, 'duckduckgo');
      expect(entry.purpose, EgressPurpose.translation);
      expect('${entry.toMap()}', isNot(contains('secret')));
    });

    test('records the engine of a query (text-to-speech)', () async {
      await recording().get(
        Uri.parse(
          'https://mozhi.example/api/tts?engine=Google&lang=en&text=hi',
        ),
      );
      expect(single().engine, 'google');
    });

    test('records the engine of a multipart body (photos)', () async {
      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('https://mozhi.example/api/image'),
            )
            ..fields['engine'] = 'google'
            ..files.add(http.MultipartFile.fromBytes('image', [1, 2, 3]));
      await (await recording().send(request)).stream.drain<void>();
      expect(single().engine, 'google');
    });

    test('records several engines', () async {
      await recording().post(
        Uri.parse('https://mozhi.example/api/translate'),
        body: {'engine': 'google,deepl', 'text': 'x'},
      );
      expect(single().engine, 'google,deepl');
    });

    test('records nothing for requests without content', () async {
      await recording().get(
        Uri.parse('https://mozhi.example/api/source_languages?engine=google'),
      );
      expect(single().purpose, EgressPurpose.catalog);
      expect(single().engine, isNull);
    });

    test('records nothing that is not a plain engine id', () async {
      await recording().post(
        Uri.parse('https://mozhi.example/api/translate'),
        body: {'engine': 'my secret text', 'text': 'x'},
      );
      await recording().post(
        Uri.parse('https://mozhi.example/api/translate'),
        body: 'engine=google',
      );
      await recording().post(
        Uri.parse('https://mozhi.example/api/translate'),
        body: jsonEncode({'engine': 'google'}),
        headers: {'content-type': 'application/json'},
      );
      expect(
        [for (final entry in ledger.entries) entry.engine],
        [null, null, null],
      );
    });
  });
}
