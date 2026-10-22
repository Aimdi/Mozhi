@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// Regression tests against real loopback servers and the default
/// `dart:io` client, whose redirect, abort and credential handling the
/// `MockClient` tests cannot show.
void main() {
  group('MozhiApiClient over dart:io', () {
    final servers = <HttpServer>[];
    final clients = <MozhiApiClient>[];

    Future<HttpServer> serve(
      Future<void> Function(HttpRequest request) handle,
    ) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      server.listen((request) async {
        await handle(request);
        await request.response.close();
      });
      return server;
    }

    MozhiApiClient clientFor(String base, {Duration? timeout}) {
      final client = MozhiApiClient(
        baseUrl: Uri.parse(base),
        timeout: timeout ?? const Duration(seconds: 10),
      );
      clients.add(client);
      return client;
    }

    tearDown(() async {
      for (final client in clients) {
        client.close();
      }
      clients.clear();
      for (final server in servers) {
        await server.close(force: true);
      }
      servers.clear();
    });

    /// A Mozhi stand-in that records the method, path and decoded form of
    /// each request. With [redirectStatus], a reverse proxy in front of it
    /// on the same server answers every request outside `/v2` with that
    /// status to the same address under `/v2`.
    Future<(HttpServer, List<Map<String, Object>>)> instance({
      int? redirectStatus,
    }) async {
      final seen = <Map<String, Object>>[];
      final server = await serve((request) async {
        final path = request.uri.path;
        if (redirectStatus != null && !path.startsWith('/v2/')) {
          await request.drain<void>();
          request.response
            ..statusCode = redirectStatus
            ..headers.set(
              'location',
              request.requestedUri.replace(path: '/v2$path').toString(),
            );
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        seen.add({
          'request': '${request.method} $path',
          'form': Uri.splitQueryString(body),
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          path.endsWith('/api/version') ? versionJson : googleTranslationJson,
        );
      });
      return (server, seen);
    }

    /// A reverse proxy that answers everything with [status] to [target], a
    /// different server.
    Future<HttpServer> redirectingProxy(int status, HttpServer target) =>
        serve((request) async {
          await request.drain<void>();
          request.response
            ..statusCode = status
            ..headers.set(
              'location',
              'http://127.0.0.1:${target.port}${request.uri}',
            );
        });

    for (final status in [301, 302, 307, 308]) {
      test(
        'follows a $status from a reverse proxy for POST like for GET',
        () async {
          final (server, seen) = await instance(redirectStatus: status);
          final client = clientFor('http://127.0.0.1:${server.port}');

          await client.ping();
          final translation = await client.translate(
            engine: 'google',
            from: 'auto',
            to: 'en',
            text: '猫 & co',
          );

          expect(translation.translatedText, 'cat');
          expect(seen, [
            {'request': 'GET /v2/api/version', 'form': <String, String>{}},
            {
              'request': 'POST /v2/api/translate',
              'form': {
                'engine': 'google',
                'from': 'auto',
                'to': 'en',
                'text': '猫 & co',
              },
            },
          ]);
        },
      );
    }

    test('sends nothing to a different server it is redirected to', () async {
      final (target, seen) = await instance();
      final proxy = await redirectingProxy(307, target);
      final client = clientFor('http://127.0.0.1:${proxy.port}');

      await expectLater(
        client.translate(engine: 'google', from: 'auto', to: 'en', text: 'x'),
        throwsA(
          isA<MozhiApiException>()
              .having((e) => e.statusCode, 'statusCode', 307)
              .having(
                (e) => e.message,
                'message',
                'Redirected to http://127.0.0.1:${target.port}, a different '
                    'server. Add that address as an instance to use it.',
              ),
        ),
      );
      await expectLater(
        client.getVersion(),
        throwsA(
          isA<MozhiApiException>().having((e) => e.statusCode, 'status', 307),
        ),
      );
      expect(seen, isEmpty);
    });

    test('does not turn a POST into a GET without the form on 303', () async {
      final (server, seen) = await instance(redirectStatus: 303);

      await expectLater(
        clientFor('http://127.0.0.1:${server.port}')
            .translate(engine: 'google', from: 'auto', to: 'en', text: 'x'),
        throwsA(
          isA<MozhiApiException>()
              .having((e) => e.statusCode, 'statusCode', 303)
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
      expect(seen, isEmpty);
    });

    test('closes the connection when the timeout runs out', () async {
      final socketServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(socketServer.close);
      final closedByClient = Completer<void>();
      socketServer.listen((socket) {
        // Read the request but never answer it.
        socket.listen(
          (_) {},
          onDone: () {
            closedByClient.complete();
            socket.destroy();
          },
          onError: (_) {},
        );
      });
      final client = clientFor(
        'http://127.0.0.1:${socketServer.port}',
        timeout: const Duration(milliseconds: 100),
      );

      await expectLater(
        client.translate(engine: 'google', from: 'auto', to: 'en', text: 'x'),
        throwsA(
          isA<MozhiApiException>().having(
            (e) => e.message,
            'message',
            'No response within 100 ms',
          ),
        ),
      );
      // Well before the client is closed in tearDown.
      await closedByClient.future.timeout(const Duration(seconds: 5));
    });

    test('reports a connection that cannot be made as a network error, '
        'not a timeout', () async {
      // Accepts the connection but never answers the TLS handshake.
      final socketServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(socketServer.close);
      final sockets = <Socket>[];
      socketServer.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {}, onError: (_) {});
      });
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      final client = MozhiApiClient(
        baseUrl: Uri.parse('https://127.0.0.1:${socketServer.port}'),
        httpClient: IOClient(
          HttpClient()..connectionTimeout = const Duration(milliseconds: 100),
        ),
      );
      clients.add(client);

      await expectLater(
        client.translate(engine: 'google', from: 'auto', to: 'en', text: 'x'),
        throwsA(
          isA<MozhiApiException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.message, 'message', contains('timed out'))
              .having(
                (e) => e.message,
                'message',
                isNot(startsWith('No response within')),
              )
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
    });

    test('sends percent-encoded credentials decoded', () async {
      String? authorization;
      final server = await serve((request) async {
        authorization = request.headers.value('authorization');
        request.response.write(versionJson);
      });

      await clientFor('http://me:p%40ss%20w%C3%B6rd@127.0.0.1:${server.port}')
          .getVersion();

      expect(
        authorization,
        'Basic ${base64Encode(utf8.encode('me:p@ss wörd'))}',
      );
    });
  });
}
