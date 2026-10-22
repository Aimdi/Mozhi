@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/network/http_client_factory_io.dart';
import 'package:mozhi/core/network/http_proxy_tunnel.dart';
import 'package:mozhi_api/mozhi_api.dart' show MozhiApiClient;
import 'package:translation_repository/translation_repository.dart';

/// Real sockets, whatever `HttpOverrides` the test binding installs.
class _RealHttp extends HttpOverrides;

/// What a fake proxy saw: the first line of each request.
typedef _ProxyLog = List<String>;

void main() {
  final servers = <Object>[];

  tearDown(() async {
    for (final server in servers) {
      switch (server) {
        case HttpServer():
          await server.close(force: true);
        case ServerSocket():
          await server.close();
      }
    }
    servers.clear();
  });

  Future<T> real<T>(Future<T> Function() body) =>
      HttpOverrides.runWithHttpOverrides(body, _RealHttp());

  /// A server that answers with the request headers as JSON and sets a
  /// cookie.
  Future<HttpServer> echoServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name] = values.join());
      request.response
        ..headers.set('set-cookie', 'session=1; Path=/')
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'path': request.uri.path, 'headers': headers}));
      await request.response.close();
    });
    return server;
  }

  /// A CONNECT proxy that logs the first line of each request and then
  /// either answers [refuse] and hangs up, answers [answer] (acting as the
  /// server too), or tunnels to [target] on loopback.
  Future<(ServerSocket, _ProxyLog)> connectProxy({
    int? target,
    String? refuse,
    String? answer,
  }) async {
    final log = <String>[];
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(proxy);
    proxy.listen((client) {
      final buffer = <int>[];
      late StreamSubscription<Uint8List> subscription;
      subscription = client.listen((data) async {
        if (target == null && log.isNotEmpty) return;
        buffer.addAll(data);
        final text = latin1.decode(buffer);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        log.add(text.split('\r\n').first);
        if (refuse != null) {
          client.add(latin1.encode(refuse));
          await client.flush();
          client.destroy();
          await subscription.cancel();
          return;
        }
        if (answer != null) {
          client.add(latin1.encode(answer));
          return;
        }
        subscription.pause();
        final upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          target!,
        );
        client.add(
          latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
        );
        final rest = buffer.sublist(end + 4);
        if (rest.isNotEmpty) upstream.add(rest);
        subscription
          ..onData(upstream.add)
          ..onDone(upstream.destroy)
          ..resume();
        upstream.listen(client.add, onDone: client.destroy);
      });
    });
    return (proxy, log);
  }

  group('createHttpClient', () {
    test('sends a bare User-Agent, no cookies and no referer', () async {
      final server = await echoServer();
      final url = Uri.parse('http://127.0.0.1:${server.port}/api/engines');

      final bodies = await real(() async {
        final client = createHttpClient();
        addTearDown(client.close);
        return [
          for (var i = 0; i < 2; i++)
            jsonDecode((await client.get(url)).body) as Map<String, dynamic>,
        ];
      });

      for (final body in bodies) {
        final headers = body['headers'] as Map<String, dynamic>;
        expect(headers['user-agent'], appUserAgent);
        expect(headers, isNot(contains('cookie')));
        expect(headers, isNot(contains('referer')));
      }
    });

    test('a blank proxy means direct connections', () async {
      final server = await echoServer();

      final response = await real(() async {
        final client = createHttpClient(proxy: '  ');
        addTearDown(client.close);
        return await client.get(Uri.parse('http://127.0.0.1:${server.port}/x'));
      });

      expect(response.statusCode, 200);
    });

    test('an invalid proxy refuses every request', () async {
      final client = createHttpClient(proxy: 'socks5://127.0.0.1:9050');

      await expectLater(
        client.get(Uri.parse('https://mozhi.example/api/engines#top')),
        throwsA(
          isA<InvalidProxyException>()
              .having(
                (e) => e.message,
                'message',
                InvalidProxyException.defaultMessage,
              )
              .having(
                (e) => e.uri.toString(),
                'uri',
                'https://mozhi.example/api/engines',
              ),
        ),
      );
    });

    group('with a proxy', () {
      test(
        'tunnels plain http with CONNECT; the proxy resolves the name',
        () async {
          final server = await echoServer();
          final (proxy, log) = await connectProxy(target: server.port);

          final body = await real(() async {
            final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
            addTearDown(client.close);
            return jsonDecode(
              (await client.get(
                Uri.parse('http://mozhi.example.onion/api/engines'),
              )).body,
            ) as Map<String, dynamic>;
          });

          expect(log, ['CONNECT mozhi.example.onion:80 HTTP/1.1']);
          expect(body['path'], '/api/engines');
          expect((body['headers'] as Map)['host'], 'mozhi.example.onion');
        },
      );

      test('reads what the proxy sent along with its answer', () async {
        final (proxy, log) = await connectProxy(
          answer:
              'HTTP/1.0 200 OK\r\n\r\n'
              'HTTP/1.1 200 OK\r\ncontent-length: 2\r\n'
              'connection: close\r\n\r\nok',
        );

        final response = await real(() async {
          final client = createHttpClient(
            proxy: 'http://127.0.0.1:${proxy.port}/',
          );
          addTearDown(client.close);
          return await client.get(
            Uri.parse('http://mozhi.example/api/version'),
          );
        });

        expect(log, ['CONNECT mozhi.example:80 HTTP/1.1']);
        expect(response.body, 'ok');
      });

      test('reports a refusing proxy', () async {
        final (proxy, _) = await connectProxy(
          refuse: 'HTTP/1.0 405 Method Not Allowed\r\n\r\n',
        );

        await expectLater(
          real(() async {
            final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
            addTearDown(client.close);
            return await client.get(Uri.parse('http://abc.onion/api/engines'));
          }),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              contains('refused the connection to abc.onion:80 (HTTP 405)'),
            ),
          ),
        );
      });

      for (final (name, answer) in [
        ('garbage', 'SSH-2.0-OpenSSH\r\n\r\n'),
        ('a closed connection', ''),
      ]) {
        test('reports $name from the proxy', () async {
          final (proxy, _) = await connectProxy(refuse: answer);

          await expectLater(
            real(() async {
              final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
              addTearDown(client.close);
              return await client.get(Uri.parse('http://abc.onion/'));
            }),
            throwsA(
              isA<http.ClientException>().having(
                (e) => e.message,
                'message',
                startsWith('The proxy'),
              ),
            ),
          );
        });
      }

      test('reports an endless proxy answer', () async {
        final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(proxy);
        proxy.listen((client) {
          client
            ..add(Uint8List(20 * 1024))
            ..listen((_) {});
        });

        await expectLater(
          real(() async {
            final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
            addTearDown(client.close);
            return await client.get(Uri.parse('http://abc.onion/'));
          }),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              'The proxy sent an invalid answer',
            ),
          ),
        );
      });

      test('connects to this device and the LAN directly', () async {
        final server = await echoServer();
        final (proxy, log) = await connectProxy(target: server.port);

        final response = await real(() async {
          final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
          addTearDown(client.close);
          return await client.get(
            Uri.parse('http://127.0.0.1:${server.port}/'),
          );
        });

        expect(response.statusCode, 200);
        expect(log, isEmpty);
      });

      test('connects to a local https server directly', () async {
        // Nothing listens on TLS here: the direct attempt fails without the
        // proxy ever being asked.
        final (proxy, log) = await connectProxy(answer: '');
        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close();

        await expectLater(
          real(() async {
            final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
            addTearDown(client.close);
            return await client.get(Uri.parse('https://127.0.0.1:$port/'));
          }),
          throwsA(isA<http.ClientException>()),
        );
        expect(log, isEmpty);
      });

      test('sends https to public hosts through the proxy', () async {
        final (proxy, log) = await connectProxy(
          refuse: 'HTTP/1.1 403 Forbidden\r\n\r\n',
        );

        await expectLater(
          real(() async {
            final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
            addTearDown(client.close);
            return await client.get(
              Uri.parse('https://mozhi.example/api/engines'),
            );
          }),
          throwsA(isA<http.ClientException>()),
        );
        expect(log, ['CONNECT mozhi.example:443 HTTP/1.1']);
      });
    });
  });

  group('createIoHttpClient', () {
    test('connects within connectTimeout and keeps idle connections', () {
      final client = createIoHttpClient();
      addTearDown(client.close);

      expect(client.connectionTimeout, connectTimeout);
      expect(client.idleTimeout, idleConnectionTimeout);
      expect(client.userAgent, appUserAgent);
    });

    test('allows proxyConnectTimeout through a proxy', () {
      final client = createIoHttpClient(
        proxy: const ProxyAddress('127.0.0.1', 8118),
      );
      addTearDown(client.close);

      expect(client.connectionTimeout, proxyConnectTimeout);
      expect(client.idleTimeout, idleConnectionTimeout);
    });

    test('gives up connecting long before a Mozhi request times out', () {
      expect(connectTimeout, const Duration(seconds: 7));
      expect(proxyConnectTimeout, const Duration(seconds: 20));
      expect(idleConnectionTimeout, const Duration(seconds: 90));
      expect(proxyConnectTimeout, lessThan(MozhiApiClient.defaultTimeout));
    });

    test('a server that never answers the handshake fails over to the next '
        'instance, also for a translation', () async {
      // Accepts connections but never answers TLS: what a host that drops
      // packets looks like to the client, minus the TCP handshake.
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(silent);
      final silentSockets = <Socket>[];
      silent.listen((socket) {
        silentSockets.add(socket);
        socket.listen((_) {}, onError: (_) {});
      });
      addTearDown(() {
        for (final socket in silentSockets) {
          socket.destroy();
        }
      });
      final answering = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(answering);
      answering.listen((request) async {
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"engine":"google","translated-text":"Hallo"}');
        await request.response.close();
      });
      final repository =
          TranslationRepository(
              mozhiClientFactory: (baseUrl) => MozhiApiClient(
                baseUrl: baseUrl,
                httpClient: IOClient(
                  createIoHttpClient(
                    connectionTimeout: const Duration(milliseconds: 300),
                  ),
                ),
              ),
            )
            ..updatePrivacy(mode: PrivacyMode.online)
            ..updateConfiguration(
              instances: [
                MozhiInstance(url: 'https://127.0.0.1:${silent.port}'),
                MozhiInstance(url: 'http://127.0.0.1:${answering.port}'),
              ],
              providers: const [],
            );
      addTearDown(repository.dispose);

      final results = await real(
        () => repository
            .translate(
              TranslationEngine.mozhi('google', 'Google'),
              const TranslationRequest(
                text: 'Hello',
                source: Language(code: 'en', name: 'English'),
                target: Language(code: 'de', name: 'German'),
              ),
            )
            .toList(),
      );

      expect(results.last.text, 'Hallo');
      expect(silentSockets, hasLength(1));
      expect(
        repository.activeInstance?.url,
        'http://127.0.0.1:${answering.port}',
      );
    });
  });

  test('bypassesProxy', () {
    expect(bypassesProxy('localhost'), isTrue);
    expect(bypassesProxy('192.168.1.2'), isTrue);
    expect(bypassesProxy('NAS.local'), isTrue);
    expect(bypassesProxy('abc.onion'), isFalse);
    expect(bypassesProxy('abc.b32.i2p'), isFalse);
    expect(bypassesProxy('mozhi.example'), isFalse);
  });

  test('connectAuthority brackets IPv6', () {
    expect(connectAuthority('abc.onion', 80), 'abc.onion:80');
    expect(connectAuthority('2001:db8::1', 443), '[2001:db8::1]:443');
  });

  group('connectTunnel', () {
    test(
      'hands over a socket that reads and writes through the proxy',
      () async {
        final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(echo);
        echo.listen(
          (socket) => socket.listen(socket.add, onDone: socket.destroy),
        );
        final (proxy, log) = await connectProxy(target: echo.port);

        final task = await connectTunnel(
          ProxyAddress('127.0.0.1', proxy.port),
          '2001:db8::1',
          7,
        );
        final socket = await task.socket;
        final received = <int>[];
        final done = Completer<void>();
        final subscription =
            socket.listen((data) {
                received.addAll(data);
                if (utf8.decode(received).endsWith('!')) done.complete();
              })
              ..pause()
              ..resume();

        socket
          ..encoding = utf8
          ..write('a')
          ..writeln('b')
          ..writeCharCode(0x63)
          ..writeAll(['d', 'e'], '-')
          ..add(utf8.encode('f'));
        await socket.addStream(Stream.value(utf8.encode('!')));
        await socket.flush();
        await done.future;

        expect(log, ['CONNECT [2001:db8::1]:7 HTTP/1.1']);
        expect(utf8.decode(received), 'ab\ncd-ef!');
        expect(socket.encoding, utf8);
        expect(socket.port, greaterThan(0));
        expect(socket.remotePort, proxy.port);
        expect(socket.address.isLoopback, isTrue);
        expect(socket.remoteAddress.isLoopback, isTrue);
        expect(socket.setOption(SocketOption.tcpNoDelay, true), isTrue);
        final option = RawSocketOption.fromBool(
          RawSocketOption.levelTcp,
          Platform.isMacOS ? 0x01 : 1,
          true,
        );
        socket.setRawOption(option);
        expect(socket.getRawOption(option), isNotEmpty);

        expect(() => socket.addError(StateError('x')), throwsUnsupportedError);
        await socket.close();
        await socket.done.catchError((Object _) {});
        socket.destroy();
        await subscription.cancel();
      },
    );

    test('cancelling closes the connection attempt', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(silent);
      silent.listen((client) => client.listen((_) {}));

      final task = await connectTunnel(
        ProxyAddress('127.0.0.1', silent.port),
        'abc.onion',
        80,
      );
      task.cancel();

      await expectLater(task.socket, throwsA(isA<SocketException>()));
    });

    test('ends the reader when the proxy hangs up later', () async {
      final opened = Completer<Socket>();
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(proxy);
      proxy.listen((client) {
        client.listen((_) {
          if (opened.isCompleted) return;
          client.add(latin1.encode('HTTP/1.1 200 OK\r\n\r\n'));
          opened.complete(client);
        });
      });

      final task = await connectTunnel(
        ProxyAddress('127.0.0.1', proxy.port),
        'abc.onion',
        80,
      );
      final socket = await task.socket;
      final closed = Completer<void>();
      socket.listen((_) {}, onDone: closed.complete, onError: (Object _) {});
      (await opened.future).destroy();

      await closed.future;
    });
  });

  group('connectTunnel with a fake proxy connection', () {
    const proxy = ProxyAddress('proxy.lan', 8118);

    test('drops a connection that opens after the cancellation', () async {
      final socket = _FakeSocket();
      final opening = Completer<Socket>();
      final task = await connectTunnel(
        proxy,
        'abc.onion',
        80,
        connect: (host, port) async {
          expect((host, port), ('proxy.lan', 8118));
          return ConnectionTask.fromSocket(opening.future, () {});
        },
      );

      task.cancel();
      opening.complete(socket);

      await expectLater(task.socket, throwsA(isA<SocketException>()));
      expect(socket.destroyed, isTrue);
      expect(socket.written, isEmpty);
    });

    test('cancelling closes an open connection', () async {
      final socket = _FakeSocket();
      final task = await connectTunnel(
        proxy,
        'abc.onion',
        80,
        connect: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(socket), () {}),
      );
      await pumpEventQueue();

      task.cancel();

      expect(socket.destroyed, isTrue);
      expect(latin1.decode(socket.written), startsWith('CONNECT abc.onion:80'));
    });
  });

  group('https through a proxy', () {
    // A certificate for the test servers' names, made for this run (never
    // stored in the repository); the client trusts it through [trust].
    late SecurityContext serverContext;
    late SecurityContext trust;
    String? skip;

    setUpAll(() async {
      final dir = await Directory.systemTemp.createTemp('mozhi_tls');
      final key = '${dir.path}/key.pem';
      final cert = '${dir.path}/cert.pem';
      ProcessResult made;
      try {
        made = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'ec',
          '-pkeyopt',
          'ec_paramgen_curve:prime256v1',
          '-nodes',
          '-keyout',
          key,
          '-out',
          cert,
          '-days',
          '2',
          '-subj',
          '/CN=mozhi.example',
          '-addext',
          'subjectAltName=DNS:mozhi.example,DNS:b.example',
        ]);
      } on ProcessException {
        skip = 'openssl is not installed';
        return;
      }
      if (made.exitCode != 0) {
        skip = 'openssl failed: ${made.stderr}';
        return;
      }
      serverContext = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key);
      trust = SecurityContext()..setTrustedCertificates(cert);
      await dir.delete(recursive: true);
    });

    /// An https server answering `ok` (or the Mozhi translation "Hallo"
    /// for `/api/translate`).
    Future<HttpServer> tlsServer() async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      servers.add(server);
      server.listen((request) async {
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            request.uri.path.endsWith('/translate')
                ? '{"engine":"google","translated-text":"Hallo"}'
                : '{"ok":true}',
          );
        await request.response.close();
      });
      return server;
    }

    /// A server that accepts connections and never answers.
    Future<ServerSocket> silentServer() async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(silent);
      final sockets = <Socket>[];
      silent.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {}, onError: (_) {});
      });
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      return silent;
    }

    /// A CONNECT proxy that tunnels each host to the loopback port
    /// [targets] names, logging the first line of each request.
    Future<(ServerSocket, _ProxyLog)> routingProxy(
      Map<String, int> targets,
    ) async {
      final log = <String>[];
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(proxy);
      proxy.listen((client) {
        final buffer = <int>[];
        late StreamSubscription<Uint8List> subscription;
        subscription = client.listen((data) async {
          buffer.addAll(data);
          final text = latin1.decode(buffer);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          final line = text.split('\r\n').first;
          log.add(line);
          subscription.pause();
          final host = line.split(' ')[1].split(':').first;
          final upstream = await Socket.connect(
            InternetAddress.loopbackIPv4,
            targets[host]!,
          );
          client.add(
            latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
          );
          subscription
            ..onData(upstream.add)
            ..onDone(() {
              upstream.destroy();
              unawaited(subscription.cancel());
            })
            ..resume();
          upstream.listen(
            client.add,
            onDone: client.destroy,
            onError: (_) => client.destroy(),
          );
        });
      });
      return (proxy, log);
    }

    test('runs TLS through the tunnel and keeps it open', () async {
      if (skip != null) return markTestSkipped(skip!);
      final server = await tlsServer();
      final (proxy, log) = await connectProxy(target: server.port);

      final bodies = await real(() async {
        final client = IOClient(
          createIoHttpClient(
            proxy: ProxyAddress('127.0.0.1', proxy.port),
            context: trust,
          ),
        );
        addTearDown(client.close);
        return [
          for (var i = 0; i < 2; i++)
            (await client.get(Uri.parse('https://mozhi.example/api/x'))).body,
        ];
      });

      expect(bodies, ['{"ok":true}', '{"ok":true}']);
      // One tunnel for both requests: the connection is kept alive.
      expect(log, ['CONNECT mozhi.example:443 HTTP/1.1']);
    });

    test('refuses a certificate the system does not trust', () async {
      if (skip != null) return markTestSkipped(skip!);
      final server = await tlsServer();
      final (proxy, _) = await connectProxy(target: server.port);

      await expectLater(
        real(() async {
          final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
          addTearDown(client.close);
          return await client.get(Uri.parse('https://mozhi.example/'));
        }),
        // As for a direct connection: TLS errors are not wrapped.
        throwsA(isA<HandshakeException>()),
      );
    });

    for (final (name, answers) in [
      ('the server never answers TLS through the tunnel', true),
      ('the proxy never answers CONNECT', false),
    ]) {
      test('gives up after the connect timeout when $name', () async {
        final silent = await silentServer();
        final ServerSocket proxy;
        if (answers) {
          (proxy, _) = await connectProxy(target: silent.port);
        } else {
          proxy = silent;
        }
        final stopwatch = Stopwatch()..start();

        await expectLater(
          real(() async {
            final client = IOClient(
              createIoHttpClient(
                proxy: ProxyAddress('127.0.0.1', proxy.port),
                connectionTimeout: const Duration(milliseconds: 300),
              ),
            );
            addTearDown(client.close);
            return await client.get(Uri.parse('https://mozhi.example/'));
          }),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              contains('timed out'),
            ),
          ),
        );
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
      });
    }

    test('a server that never answers through the proxy fails over to the '
        'next instance, also for a translation', () async {
      if (skip != null) return markTestSkipped(skip!);
      final silent = await silentServer();
      final answering = await tlsServer();
      final (proxy, log) = await routingProxy({
        'mozhi.example': silent.port,
        'b.example': answering.port,
      });
      final repository =
          TranslationRepository(
              mozhiClientFactory: (baseUrl) => MozhiApiClient(
                baseUrl: baseUrl,
                httpClient: IOClient(
                  createIoHttpClient(
                    proxy: ProxyAddress('127.0.0.1', proxy.port),
                    connectionTimeout: const Duration(milliseconds: 300),
                    context: trust,
                  ),
                ),
              ),
            )
            ..updatePrivacy(mode: PrivacyMode.online)
            ..updateConfiguration(
              instances: const [
                MozhiInstance(url: 'https://mozhi.example'),
                MozhiInstance(url: 'https://b.example'),
              ],
              providers: const [],
            );
      addTearDown(repository.dispose);

      final results = await real(
        () => repository
            .translate(
              TranslationEngine.mozhi('google', 'Google'),
              const TranslationRequest(
                text: 'Hello',
                source: Language(code: 'en', name: 'English'),
                target: Language(code: 'de', name: 'German'),
              ),
            )
            .toList(),
      );

      expect(results.last.text, 'Hallo');
      expect(log, [
        'CONNECT mozhi.example:443 HTTP/1.1',
        'CONNECT b.example:443 HTTP/1.1',
      ]);
      expect(repository.activeInstance?.url, 'https://b.example');
    });

    test('reports a proxy that refuses the tunnel', () async {
      final (proxy, _) = await connectProxy(
        refuse: 'HTTP/1.1 403 Forbidden\r\n\r\n',
      );

      await expectLater(
        real(() async {
          final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
          addTearDown(client.close);
          return await client.get(Uri.parse('https://mozhi.example/'));
        }),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('refused the connection to mozhi.example:443 (HTTP 403)'),
          ),
        ),
      );
    });

    for (final (name, answer, message) in [
      (
        'data before TLS',
        'HTTP/1.1 200 OK\r\n\r\nhello',
        'The proxy sent an invalid answer',
      ),
      (
        'garbage',
        'SSH-2.0-OpenSSH\r\n\r\n',
        'The proxy sent an invalid answer',
      ),
    ]) {
      test('reports $name from the proxy', () async {
        final (proxy, _) = await connectProxy(answer: answer);

        await expectLater(
          real(() async {
            final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
            addTearDown(client.close);
            return await client.get(Uri.parse('https://mozhi.example/'));
          }),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
      });
    }

    test('reports a proxy that hangs up or answers endlessly', () async {
      final (closing, _) = await connectProxy(refuse: '');
      final endless = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(endless);
      endless.listen((client) {
        client
          ..add(Uint8List(20 * 1024))
          ..listen((_) {});
      });

      for (final (port, message) in [
        (closing.port, 'The proxy closed the connection'),
        (endless.port, 'The proxy sent an invalid answer'),
      ]) {
        await expectLater(
          real(() async {
            final client = createHttpClient(proxy: '127.0.0.1:$port');
            addTearDown(client.close);
            return await client.get(Uri.parse('https://mozhi.example/'));
          }),
          throwsA(
            isA<http.ClientException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
      }
    });

    test('a connection error before the answer is reported', () async {
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(proxy);
      proxy.listen((client) => client.listen((_) => client.destroy()));

      await expectLater(
        real(() async {
          final client = createHttpClient(proxy: '127.0.0.1:${proxy.port}');
          addTearDown(client.close);
          return await client.get(Uri.parse('https://mozhi.example/'));
        }),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('connectSecureTunnel with a fake proxy connection', () {
    const proxy = ProxyAddress('proxy.lan', 8118);

    test('drops a connection that opens after the cancellation', () async {
      final socket = _FakeSocket();
      final opening = Completer<Socket>();
      final task = await connectSecureTunnel(
        proxy,
        'mozhi.example',
        443,
        connect: (host, port) async {
          expect((host, port), ('proxy.lan', 8118));
          return ConnectionTask.fromSocket(opening.future, () {});
        },
      );

      task.cancel();
      opening.complete(socket);

      await expectLater(task.socket, throwsA(isA<SocketException>()));
      expect(socket.destroyed, isTrue);
      expect(socket.written, isEmpty);
    });

    test('cancelling closes an open connection', () async {
      final socket = _FakeSocket();
      final task = await connectSecureTunnel(
        proxy,
        'mozhi.example',
        443,
        connect: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(socket), () {}),
      );
      await pumpEventQueue();

      task.cancel();
      socket.incoming.addError(const SocketException('closed'));

      await expectLater(task.socket, throwsA(isA<SocketException>()));
      expect(socket.destroyed, isTrue);
      expect(
        latin1.decode(socket.written),
        startsWith('CONNECT mozhi.example:443'),
      );
    });

    test('a tunnel opened after the cancellation is dropped', () async {
      final socket = _FakeSocket();
      late final ConnectionTask<Socket> task;
      task = await connectSecureTunnel(
        proxy,
        'mozhi.example',
        443,
        connect: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(socket), () {}),
      );
      await pumpEventQueue();
      task.cancel();
      // The proxy answers after the cancellation; TLS needs a real socket,
      // so the attempt fails either way, without leaking the connection.
      socket.incoming.add(latin1.encode('HTTP/1.1 200 OK\r\n\r\n'));

      await expectLater(task.socket, throwsA(anything));
      expect(socket.destroyed, isTrue);
    });
  });

  group('openTunnel', () {
    test('fails on a connection error before the answer', () async {
      final socket = _FakeSocket();
      final tunnel = openTunnel(socket, 'abc.onion:80');

      socket.incoming.addError(const SocketException('reset'));

      await expectLater(
        tunnel,
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            startsWith('The proxy connection failed'),
          ),
        ),
      );
      expect(socket.destroyed, isTrue);
    });

    test('passes later connection errors to the reader', () async {
      final socket = _FakeSocket();
      final tunnel = openTunnel(socket, 'abc.onion:80');
      socket.incoming.add(latin1.encode('HTTP/1.1 200 OK\r\n\r\n'));
      final opened = await tunnel;
      final errors = <Object>[];
      opened.listen((_) {}, onError: errors.add);

      socket.incoming.addError(const SocketException('reset'));
      await pumpEventQueue();

      expect(errors, [isA<SocketException>()]);
    });
  });

  group('ProxyAddress.parse', () {
    for (final (input, host, port) in [
      ('127.0.0.1:8118', '127.0.0.1', 8118),
      (' localhost:9080 ', 'localhost', 9080),
      ('[::1]:8118', '::1', 8118),
      ('HTTP://proxy.lan:3128/', 'proxy.lan', 3128),
    ]) {
      test('"$input"', () {
        final address = ProxyAddress.parse(input);
        expect(address, ProxyAddress(host, port));
        expect(address.hashCode, ProxyAddress(host, port).hashCode);
      });
    }

    for (final input in [
      '',
      'localhost',
      'localhost:0',
      'localhost:70000',
      'socks5://127.0.0.1:9050',
      'user:pw@127.0.0.1:8118',
      '127.0.0.1:8118/path',
      '127.0.0.1:8118?x=1',
      '127.0.0.1:8118#x',
      'bad host:80',
      'http://[::1',
    ]) {
      test('rejects "$input"', () {
        expect(() => ProxyAddress.parse(input), throwsFormatException);
      });
    }

    test('authority and toString', () {
      expect(const ProxyAddress('::1', 8118).authority, '[::1]:8118');
      expect(
        const ProxyAddress('127.0.0.1', 8118).toString(),
        'ProxyAddress(127.0.0.1:8118)',
      );
      expect(const ProxyAddress('a', 1), isNot(const ProxyAddress('a', 2)));
    });
  });
}

/// A proxy connection whose incoming data the test writes.
class _FakeSocket extends Stream<Uint8List> implements Socket {
  final incoming = StreamController<Uint8List>();
  final written = <int>[];
  bool destroyed = false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) => written.addAll(data);

  @override
  void destroy() => destroyed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
