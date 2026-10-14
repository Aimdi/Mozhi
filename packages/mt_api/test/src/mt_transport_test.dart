import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mt_api/mt_api.dart';
import 'package:mt_api/src/mt_transport.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final Uri _uri = Uri.parse('https://mt.example/v2/thing');

MtTransport _transport(
  http.Client client, {
  Duration timeout = const Duration(seconds: 5),
}) => MtTransport(
  service: 'Test',
  timeout: timeout,
  httpClient: client,
  newException: MtApiException.new,
  mapHttpError: (response, uri) => MtApiException(
    'HTTP ${response.statusCode}',
    kind: MtErrorKind.fromStatus(response.statusCode),
    statusCode: response.statusCode,
    detail: MtTransport.serverMessage(response),
    uri: uri,
  ),
);

void main() {
  group(MtTransport, () {
    test('sends headers and a JSON body and returns 2xx responses', () async {
      final client = RecordingClient((_) => jsonResponse('{"ok":true}'));
      final json = await _transport(client).sendJson(
        'PUT',
        _uri,
        headers: {'x-test': '1', 'accept': 'text/plain'},
        json: const {'a': 'ü'},
      );
      expect(json, {'ok': true});
      final request = client.single;
      expect(request.method, 'PUT');
      expect(request.url, _uri);
      expect(request.headers['x-test'], '1');
      // Explicit headers win over the default `accept`.
      expect(request.headers['accept'], 'text/plain');
      expect(request.body, '{"a":"ü"}');
    });

    test('sends no body or content type without json', () async {
      final client = RecordingClient((_) => textResponse('', 204));
      final response = await _transport(client).send('GET', _uri);
      expect(response.statusCode, 204);
      expect(client.single.body, isEmpty);
      expect(client.single.headers.containsKey('content-type'), isFalse);
    });

    test('decodes UTF-8 bodies without a charset', () async {
      final client = RecordingClient((_) => jsonResponse('"Grüße, 世界"'));
      expect(await _transport(client).sendJson('GET', _uri), 'Grüße, 世界');
    });

    test('maps non-2xx responses with the error mapper', () {
      final client = RecordingClient(
        (_) => jsonResponse('{"error":"nope"}', status: 429),
      );
      expect(
        _transport(client).send('GET', _uri),
        throwsMtError(
          kind: MtErrorKind.rateLimited,
          statusCode: 429,
          message: 'HTTP 429',
          detail: 'nope',
          uri: _uri,
        ),
      );
    });

    test('never follows redirects', () async {
      final client = RecordingClient(
        (_) => textResponse('', 302, headers: {'location': 'https://evil/'}),
      );
      await expectLater(
        _transport(client).send('POST', _uri, json: const {'api_key': 'k'}),
        throwsMtError(kind: MtErrorKind.unknown, statusCode: 302, uri: _uri),
      );
      expect(client.single.followRedirects, isFalse);
      expect(client.single.maxRedirects, 0);
    });

    test('maps 1xx-less-than-200 and 3xx statuses as errors', () async {
      for (final status in [199, 300, 301]) {
        final client = RecordingClient((_) => textResponse('', status));
        await expectLater(
          _transport(client).send('GET', _uri),
          throwsMtError(kind: MtErrorKind.unknown, statusCode: status),
        );
      }
    });

    test('maps invalid JSON', () {
      final client = RecordingClient((_) => jsonResponse('{oops'));
      expect(
        _transport(client).sendJson('GET', _uri),
        throwsMtError(
          kind: MtErrorKind.invalidResponse,
          message: 'Unexpected response from Test.',
          detail: startsWith('not valid JSON'),
          uri: _uri,
        ),
      );
    });

    group('transport failures', () {
      test('ClientException', () {
        final client = MockClient(
          (_) => throw http.ClientException('Failed host lookup'),
        );
        expect(
          _transport(client).send('GET', _uri),
          throwsMtError(
            kind: MtErrorKind.network,
            statusCode: isNull,
            message: 'Could not reach Test at mt.example.',
            detail: 'Failed host lookup',
            uri: _uri,
          ),
        );
      });

      test('ClientException without a message', () {
        final client = MockClient((_) => throw http.ClientException(''));
        expect(
          _transport(client).send('GET', _uri),
          throwsMtError(kind: MtErrorKind.network, detail: isNull),
        );
      });

      test('other exceptions', () {
        final client = MockClient((_) => throw const FormatException('bad'));
        expect(
          _transport(client).send('GET', _uri),
          throwsMtError(
            kind: MtErrorKind.network,
            detail: 'FormatException: bad',
          ),
        );
      });
    });

    group('timeout', () {
      test('reports whole seconds', () {
        final transport = _transport(
          HangingClient(),
          timeout: const Duration(milliseconds: 1000),
        );
        expect(
          transport.send('GET', _uri),
          throwsMtError(
            kind: MtErrorKind.timeout,
            message: 'No response from mt.example within 1 s.',
          ),
        );
      });

      test('covers the response body and aborts the request', () async {
        final abortTriggers = <Future<void>>[];
        final bodyNeverEnds = StreamController<List<int>>();
        addTearDown(bodyNeverEnds.close);
        final client = MockClient.streaming((request, _) async {
          abortTriggers.add((request as http.Abortable).abortTrigger!);
          return http.StreamedResponse(bodyNeverEnds.stream, 200);
        });
        await expectLater(
          _transport(
            client,
            timeout: const Duration(milliseconds: 30),
          ).send('GET', _uri),
          throwsMtError(
            kind: MtErrorKind.timeout,
            message: 'No response from mt.example within 30 ms.',
          ),
        );
        await expectLater(abortTriggers.single, completes);
      });
    });

    group('cancellation', () {
      test('via a client that honours abort triggers', () async {
        final client = HangingClient();
        final abort = Completer<void>();
        final future = _transport(client)
            .send('GET', _uri, abortTrigger: abort.future);
        await pumpEventQueue();
        abort.complete();
        await expectLater(
          future,
          throwsMtError(
            kind: MtErrorKind.cancelled,
            statusCode: isNull,
            message: 'The request was cancelled.',
            uri: _uri,
          ),
        );
        expect(client.sawAbort, isTrue);
      });

      test('an abort trigger that errors also cancels', () async {
        final client = HangingClient();
        final abort = Completer<void>();
        final future = _transport(client)
            .send('GET', _uri, abortTrigger: abort.future);
        abort.completeError(StateError('stop'));
        await expectLater(future, throwsMtError(kind: MtErrorKind.cancelled));
      });

      test('discards a response that arrives after cancelling', () async {
        final abort = Completer<void>();
        final client = MockClient((_) async {
          abort.complete();
          await pumpEventQueue();
          return jsonResponse('{}');
        });
        await expectLater(
          _transport(client).send('GET', _uri, abortTrigger: abort.future),
          throwsMtError(kind: MtErrorKind.cancelled),
        );
      });

      test('a trigger completing after the response is harmless', () async {
        final abort = Completer<void>();
        final client = RecordingClient((_) => jsonResponse('{}'));
        final response = await _transport(client)
            .send('GET', _uri, abortTrigger: abort.future);
        abort.complete();
        await pumpEventQueue();
        expect(response.statusCode, 200);
      });
    });

    group('expectObject / expectList', () {
      final transport = _transport(RecordingClient((_) => jsonResponse('')));

      test('accept the right shapes', () {
        expect(transport.expectObject(<String, dynamic>{'a': 1}, _uri), {
          'a': 1,
        });
        expect(transport.expectList([1], _uri), [1]);
      });

      test('reject other shapes', () {
        expect(
          () => transport.expectObject([1], _uri),
          throwsMtError(
            kind: MtErrorKind.invalidResponse,
            detail: 'expected a JSON object',
          ),
        );
        expect(
          () => transport.expectList(null, _uri),
          throwsMtError(
            kind: MtErrorKind.invalidResponse,
            detail: 'expected a JSON array',
          ),
        );
      });
    });

    group('serverMessage', () {
      String? message(String body, {Map<String, String> headers = const {}}) =>
          MtTransport.serverMessage(textResponse(body, 400, headers: headers));

      test('reads JSON error shapes', () {
        expect(message('{"message":"m"}'), 'm');
        expect(message('{"error":"e"}'), 'e');
        expect(message('{"detail":"d"}'), 'd');
        expect(message('{"message":"m","detail":"d"}'), 'm: d');
        expect(message('{"message":"same","detail":"same"}'), 'same');
        expect(message('{"error":{"message":" nested "}}'), 'nested');
        expect(message('{"message":"  ","error":"e"}'), 'e');
        expect(message('" quoted "'), 'quoted');
      });

      test('returns plain text bodies', () {
        expect(message('  Too Many Requests \n'), 'Too Many Requests');
      });

      test('ignores empty, HTML and unhelpful bodies', () {
        expect(message(''), isNull);
        expect(message('   '), isNull);
        expect(message('<h1>502</h1>'), isNull);
        expect(
          message('Bad Gateway', headers: {'content-type': 'text/html'}),
          isNull,
        );
        expect(message('{"message":1}'), isNull);
        expect(message('[1,2]'), isNull);
        expect(message('""'), isNull);
        expect(message('{"error":{"code":1}}'), isNull);
      });
    });
  });
}
