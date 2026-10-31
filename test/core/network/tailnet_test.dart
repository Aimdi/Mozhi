@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/network/http_client_factory_io.dart';
import 'package:mozhi/core/network/http_proxy_tunnel.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:translation_repository/translation_repository.dart';

const _tailnet = 'nas.tail1234.ts.net';
const _funnel = 'blog.tail1234.ts.net';

/// What the fake resolver answers.
const Map<String, List<String>> _addresses = {
  _tailnet: ['100.101.102.103', 'fd7a:115c:a1e0::7'],
  _funnel: ['192.0.2.10', '2001:db8::10'],
};

/// A phone on its tailnet: Tailscale's `tun0` has its ULA (and its
/// 100.x address), mobile data has a carrier's CGNAT address.
const List<LocalInterface> _onTailnet = [
  (name: 'rmnet_data0', addresses: ['100.70.1.2']),
  (name: 'tun0', addresses: ['100.101.0.1', 'fd7a:115c:a1e0::1']),
];

/// The same phone with Tailscale off.
const List<LocalInterface> _offTailnet = [
  (name: 'rmnet_data0', addresses: ['100.70.1.2']),
  (name: 'wlan0', addresses: ['192.168.1.20', 'fe80::1']),
];

void main() {
  late List<String> lookups;
  late List<LocalInterface> interfaces;
  late int interfaceChecks;
  late DateTime now;
  late TailnetResolver resolver;

  Future<List<String>> lookup(String host) async {
    lookups.add(host);
    final addresses = _addresses[host];
    if (addresses == null) throw SocketException('No address for $host');
    return addresses;
  }

  Future<List<LocalInterface>> listInterfaces() async {
    interfaceChecks++;
    return interfaces;
  }

  /// Lets [duration] pass on the resolver's clock.
  void wait(Duration duration) => now = now.add(duration);

  setUp(() {
    lookups = [];
    interfaces = _onTailnet;
    interfaceChecks = 0;
    now = DateTime.utc(2026, 10, 31, 12);
    resolver = TailnetResolver(
      lookup: lookup,
      interfaces: listInterfaces,
      clock: () => now,
    );
    final previous = TailnetResolver.instance;
    TailnetResolver.instance = resolver;
    addTearDown(() => TailnetResolver.instance = previous);
    addTearDown(TailnetHosts.forget);
  });

  group('TailnetResolver', () {
    test('records where Tailscale names lead, once', () async {
      await Future.wait([
        resolver.resolve(_tailnet),
        resolver.resolve('NAS.tail1234.ts.net'),
        resolver.resolve(_funnel),
        resolver.resolve('mozhi.example'),
        resolver.resolve('192.168.1.2'),
      ]);
      await resolver.resolve(_tailnet);

      expect(lookups, [_tailnet, _funnel]);
      expect(TailnetHosts.isPrivate(_tailnet), isTrue);
      expect(TailnetHosts.isKnown(_funnel), isTrue);
      expect(TailnetHosts.isPrivate(_funnel), isFalse);
      expect(DataDestination.isPrivateHost(_tailnet), isTrue);
      expect(DataDestination.isPrivateHost(_funnel), isFalse);
    });

    test('a failed lookup leaves the name public and is retried', () async {
      const unknown = 'gone.tail1234.ts.net';
      await resolver.resolve(unknown);
      await resolver.resolve(unknown);

      expect(lookups, [unknown, unknown]);
      expect(TailnetHosts.isKnown(unknown), isFalse);
      expect(DataDestination.isPrivateHost(unknown), isFalse);
    });

    test('a lookup that takes too long counts as failed', () async {
      final slow = TailnetResolver(
        lookup: (_) => Completer<List<String>>().future,
        interfaces: listInterfaces,
        timeout: const Duration(milliseconds: 10),
      );
      await slow.resolve(_tailnet);
      expect(TailnetHosts.isKnown(_tailnet), isFalse);
    });

    test('resolveUrls looks up the hosts of URLs', () async {
      await resolver.resolveUrls([
        'http://$_tailnet:11434/v1',
        '$_funnel/api',
        '',
        'https://mozhi.example',
      ]);
      expect(lookups, [_tailnet, _funnel]);
    });

    test('the default resolver answers on this platform', () async {
      // `localhost` is no Tailscale name: nothing is looked up.
      await TailnetResolver().resolve('localhost');
      expect(TailnetHosts.isKnown('localhost'), isFalse);
    });
  });

  group('a Tailscale name', () {
    test('skips the proxy only when it leads to the tailnet', () async {
      expect(bypassesProxy(_tailnet), isFalse);
      final session = NetworkSession(
        proxy: '127.0.0.1:8118',
        httpClient: MockClient((_) async => http.Response('', 200)),
      );
      addTearDown(session.close);
      expect(session.usesProxyFor(_tailnet), isTrue);

      await resolver.resolveUrls(['https://$_tailnet', 'https://$_funnel']);

      expect(bypassesProxy(_tailnet), isTrue);
      expect(session.usesProxyFor(_tailnet), isFalse);
      expect(bypassesProxy(_funnel), isFalse);
      expect(session.usesProxyFor(_funnel), isTrue);
    });

    test('may be entered with plain http until it turns out public', () async {
      final tailnet = Uri.parse('http://$_tailnet:11434');
      final funnel = Uri.parse('http://$_funnel');
      const policy = NetworkPolicy(hasProxy: false);
      // Not looked up yet: settings take it, requests do not.
      expect(isCleartextAllowed(funnel), isTrue);
      expect(isInsecureHttp(funnel), isFalse);
      expect(isCleartextAllowedNow(funnel), isFalse);
      expect(
        () => policy.check(funnel),
        throwsA(isA<CleartextRefusedException>()),
      );

      await resolver.resolveUrls(['$tailnet', '$funnel']);

      expect(isCleartextAllowed(tailnet), isTrue);
      expect(isCleartextAllowedNow(tailnet), isTrue);
      expect(isInsecureHttp(tailnet), isFalse);
      policy.check(tailnet);
      expect(isCleartextAllowed(funnel), isFalse);
      expect(isInsecureHttp(funnel), isTrue);
      expect(isCleartextAllowed(Uri.parse('https://$_funnel')), isTrue);
    });

    test('may use plain http only when it leads to the tailnet', () async {
      final sent = <Uri>[];
      final client = BackendHttpClient(
        MockClient((request) async {
          sent.add(request.url);
          return http.Response('ok', 200);
        }),
        policy: const NetworkPolicy(hasProxy: false),
      );

      await client.get(Uri.parse('http://$_tailnet:11434/api/tags'));
      await expectLater(
        client.get(Uri.parse('http://$_funnel/api')),
        throwsA(isA<CleartextRefusedException>()),
      );
      await client.get(Uri.parse('https://$_funnel/api'));

      expect(sent, [
        Uri.parse('http://$_tailnet:11434/api/tags'),
        Uri.parse('https://$_funnel/api'),
      ]);
      expect(lookups, [_tailnet, _funnel]);
    });

    test('is looked up by the client it is given', () async {
      final asked = <String>[];
      final client = BackendHttpClient(
        MockClient((_) async => http.Response('ok', 200)),
        policy: const NetworkPolicy(hasProxy: false),
        resolveHost: (host) async {
          asked.add(host);
          TailnetHosts.record(host, ['100.64.0.9']);
        },
      );

      await client.get(Uri.parse('http://$_funnel/'));

      expect(asked, [_funnel]);
      expect(lookups, isEmpty);
    });

    test('a public server may not redirect to one, without a lookup', () async {
      final client = BackendHttpClient(
        MockClient((request) async {
          if (request.url.host == 'mirror.example') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://$_funnel/m'},
            );
          }
          return http.Response('ok', 200);
        }),
        policy: const NetworkPolicy(hasProxy: false),
      );

      await expectLater(
        client.get(Uri.parse('https://mirror.example/a')),
        throwsA(isA<RedirectRefusedException>()),
      );
      expect(lookups, isEmpty);
    });

    test('a tailnet server may redirect to another, looked up', () async {
      final client = BackendHttpClient(
        MockClient((request) async {
          if (request.url.host == _tailnet) {
            return http.Response(
              '',
              302,
              headers: {'location': 'http://$_funnel/m'},
            );
          }
          return http.Response('ok', 200);
        }),
        policy: const NetworkPolicy(hasProxy: false),
      );

      // The target turns out to be public: no plain http.
      await expectLater(
        client.get(Uri.parse('http://$_tailnet/a')),
        throwsA(isA<CleartextRefusedException>()),
      );
      expect(lookups, [_tailnet, _funnel]);
    });

    test('a web page request looks it up first', () async {
      final client = WebsiteHttpClient(
        MockClient((_) async => http.Response('ok', 200)),
        policy: const NetworkPolicy(hasProxy: true),
      );

      await client.get(Uri.parse('http://$_funnel/page'));
      await client.get(Uri.parse('http://mozhi.example/page'));

      expect(lookups, [_funnel]);
    });

    test('routeThroughProxy decides after the lookup', () async {
      // A name on the tailnet is not routed: it is pinned (see below).
      final decided = <(String, bool)>[];
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      routeThroughProxy(
        client,
        // Nothing listens there: the attempt fails after the decision.
        const ProxyAddress('127.0.0.1', 9),
        bypass: (host) {
          decided.add((host, TailnetHosts.isKnown(host)));
          return false;
        },
        resolveHost: resolver.resolve,
      );

      await expectLater(
        HttpOverrides.runWithHttpOverrides(
          () => client.getUrl(Uri.parse('https://$_funnel/')),
          _RealHttp(),
        ),
        throwsA(isA<SocketException>()),
      );

      expect(decided, [(_funnel, true)]);
      expect(lookups, [_funnel]);
    });
  });

  group('the Tailscale interface', () {
    test('hasTailscaleInterface: the ULA anywhere, 100.64/10 only on an '
        'interface named tailscale', () {
      for (final (List<LocalInterface> list, bool up) in [
        (_onTailnet, true),
        (_offTailnet, false),
        (const [], false),
        (
          const [
            (name: 'tun0', addresses: ['fd7a:115c:a1e0:ab12::1']),
          ],
          true,
        ),
        (
          const [
            (name: 'tailscale0', addresses: ['100.101.0.1']),
          ],
          true,
        ),
        (
          const [
            (name: 'Tailscale', addresses: ['100.101.0.1']),
          ],
          true,
        ),
        // A carrier's CGNAT address, whatever the interface.
        (
          const [
            (name: 'rmnet_data0', addresses: ['100.101.0.1']),
          ],
          false,
        ),
        (
          const [
            (name: 'tun0', addresses: ['100.101.0.1']),
          ],
          false,
        ),
        (
          const [
            (name: 'tailscale0', addresses: ['192.168.1.2', 'fd00::1']),
          ],
          false,
        ),
      ]) {
        expect(
          TailnetResolver.hasTailscaleInterface(list),
          up,
          reason: '$list',
        );
      }
    });

    test('without one nothing is looked up and every name is public', () async {
      interfaces = _offTailnet;
      await resolver.resolveUrls(['https://$_tailnet', 'https://$_funnel']);

      expect(lookups, isEmpty);
      expect(TailnetHosts.isKnown(_tailnet), isFalse);
      expect(DataDestination.isPrivateHost(_tailnet), isFalse);
      expect(resolver.connectAddress(_tailnet), isNull);
    });

    test('a carrier CGNAT address alone (cellular) does not count', () async {
      interfaces = const [
        (name: 'rmnet_data0', addresses: ['100.101.0.1']),
      ];
      await resolver.resolve(_tailnet);

      expect(lookups, isEmpty);
      expect(DataDestination.isPrivateHost(_tailnet), isFalse);
    });

    test('a name recorded before any check is not trusted', () async {
      TailnetHosts.record(_funnel, ['100.64.0.9']);
      await resolver.resolve(_tailnet);

      expect(TailnetHosts.isKnown(_funnel), isFalse);
      expect(TailnetHosts.isPrivate(_tailnet), isTrue);
    });

    test('a listing that fails or hangs counts as no interface', () async {
      final failing = TailnetResolver(
        lookup: lookup,
        interfaces: () async => throw const SocketException('no'),
      );
      await failing.resolve(_tailnet);
      final hanging = TailnetResolver(
        lookup: lookup,
        interfaces: () => Completer<List<LocalInterface>>().future,
        timeout: const Duration(milliseconds: 10),
      );
      await hanging.resolve(_tailnet);

      expect(lookups, isEmpty);
      expect(TailnetHosts.isPrivate(_tailnet), isFalse);
    });

    test('is checked again for every request, at most every '
        'interfaceMaxAge', () async {
      await resolver.resolve(_tailnet);
      await resolver.resolve(_funnel);
      expect(interfaceChecks, 1);

      wait(const Duration(seconds: 1));
      await resolver.resolve(_tailnet);
      expect(interfaceChecks, 1);

      wait(resolver.interfaceMaxAge);
      await resolver.resolve(_tailnet);
      expect(interfaceChecks, 2);
      // Lookups were fresh all along.
      expect(lookups, [_tailnet, _funnel]);
    });

    test('checks running at once share one', () async {
      await Future.wait([
        resolver.resolve(_tailnet),
        resolver.resolve(_funnel),
      ]);
      expect(interfaceChecks, 1);
    });

    test('going down after a verdict makes the name public at the next '
        'request, without a lookup', () async {
      await resolver.resolveUrls(['https://$_tailnet', 'https://$_funnel']);
      expect(DataDestination.isPrivateHost(_tailnet), isTrue);
      expect(resolver.connectAddress(_tailnet), isNotNull);

      // Tailscale off, on another network.
      interfaces = _offTailnet;
      wait(resolver.interfaceMaxAge);
      final client = BackendHttpClient(
        MockClient((_) async => http.Response('ok', 200)),
        policy: const NetworkPolicy(hasProxy: false),
      );
      await expectLater(
        client.get(Uri.parse('http://$_tailnet:11434/api/tags')),
        throwsA(isA<CleartextRefusedException>()),
      );

      expect(lookups, [_tailnet, _funnel]);
      // Every record is forgotten.
      expect(TailnetHosts.isKnown(_tailnet), isFalse);
      expect(TailnetHosts.isKnown(_funnel), isFalse);
      expect(DataDestination.isPrivateHost(_tailnet), isFalse);
      expect(resolver.connectAddress(_tailnet), isNull);
    });

    test('any change of its addresses forgets every record', () async {
      await resolver.resolveUrls(['https://$_tailnet', 'https://$_funnel']);
      // Another tailnet: another address.
      interfaces = const [
        (name: 'tun0', addresses: ['fd7a:115c:a1e0::99']),
      ];
      wait(resolver.interfaceMaxAge);
      await resolver.resolve(_tailnet);

      expect(TailnetHosts.isKnown(_funnel), isFalse);
      expect(lookups, [_tailnet, _funnel, _tailnet]);
      expect(TailnetHosts.isPrivate(_tailnet), isTrue);
    });

    test('an answer to a lookup started before a change is dropped', () async {
      final answer = Completer<List<String>>();
      final racing = TailnetResolver(
        lookup: (_) => answer.future,
        interfaces: listInterfaces,
        clock: () => now,
      );
      final first = racing.resolve(_tailnet);
      await pumpEventQueue();
      // Meanwhile Tailscale went off, as another request saw.
      interfaces = _offTailnet;
      wait(racing.interfaceMaxAge);
      await racing.resolve(_funnel);
      answer.complete(_addresses[_tailnet]);
      await first;

      expect(TailnetHosts.isKnown(_tailnet), isFalse);
    });

    test('the browser and Offline only do no lookups', () async {
      // The web stub lists no interface, so nothing is looked up there.
      final web = TailnetResolver(lookup: lookup, interfaces: () async => []);
      await web.resolve(_tailnet);
      expect(lookups, isEmpty);
    });
  });

  group('a record', () {
    test('is looked up again after ttl', () async {
      await resolver.resolve(_tailnet);
      wait(resolver.ttl - const Duration(seconds: 1));
      await resolver.resolve(_tailnet);
      expect(lookups, [_tailnet]);

      wait(const Duration(seconds: 1));
      await resolver.resolve(_tailnet);
      expect(lookups, [_tailnet, _tailnet]);
      expect(resolver.ttl, TailnetHosts.ttl);
    });

    test('whose name now leads elsewhere turns public', () async {
      final answers = {
        _tailnet: ['100.101.102.103'],
      };
      final changing = TailnetResolver(
        lookup: (host) async => answers[host]!,
        interfaces: listInterfaces,
        clock: () => now,
      );
      await changing.resolve(_tailnet);
      expect(TailnetHosts.isPrivate(_tailnet), isTrue);

      answers[_tailnet] = ['203.0.113.5'];
      wait(TailnetHosts.ttl);
      await changing.resolve(_tailnet);
      expect(TailnetHosts.isPrivate(_tailnet), isFalse);
      expect(changing.connectAddress(_tailnet), isNull);
    });

    test('whose lookup fails after ttl is forgotten', () async {
      var fail = false;
      final flaky = TailnetResolver(
        lookup: (host) async =>
            fail ? throw const SocketException('down') : ['100.64.0.7'],
        interfaces: listInterfaces,
        clock: () => now,
      );
      await flaky.resolve(_tailnet);
      expect(TailnetHosts.isPrivate(_tailnet), isTrue);

      fail = true;
      wait(TailnetHosts.ttl);
      await flaky.resolve(_tailnet);
      expect(TailnetHosts.isKnown(_tailnet), isFalse);
      expect(DataDestination.isPrivateHost(_tailnet), isFalse);
    });
  });

  group('connectAddress', () {
    test('prefers the ULA when the device has one', () async {
      await resolver.resolve(_tailnet);
      expect(resolver.connectAddress(_tailnet), 'fd7a:115c:a1e0::7');
      expect(resolver.connectAddress(_funnel), isNull);
      expect(resolver.connectAddress('mozhi.example'), isNull);
    });

    test('else an address in 100.64.0.0/10', () async {
      interfaces = const [
        (name: 'tailscale0', addresses: ['100.101.0.1']),
      ];
      await resolver.resolve(_tailnet);
      expect(resolver.connectAddress(_tailnet), '100.101.102.103');
    });

    test('else the only kind there is', () async {
      final only = TailnetResolver(
        lookup: (_) async => ['100.64.0.7'],
        interfaces: listInterfaces,
        clock: () => now,
      );
      await only.resolve(_tailnet);
      expect(only.connectAddress(_tailnet), '100.64.0.7');
    });

    test('is null before any check', () {
      TailnetHosts.record(_tailnet, ['100.64.0.7']);
      expect(TailnetResolver().connectAddress(_tailnet), isNull);
    });
  });

  group('a connection to a name on the tailnet', () {
    final servers = <Object>[];
    late List<(String, int)> connected;
    late List<Object?> handshakeHosts;

    setUp(() {
      connected = [];
      handshakeHosts = [];
    });

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

    /// Answers with the `Host` header it got.
    void answerHost(HttpServer server) {
      servers.add(server);
      server.listen((request) async {
        await request.drain<void>();
        request.response.write(request.headers.value('host'));
        await request.response.close();
      });
    }

    /// A client whose connections to a checked address go to [port] on
    /// loopback instead (noting the address), with [trust].
    HttpClient pinnedClient(
      int port, {
      SecurityContext? trust,
      ProxyAddress? proxy,
    }) {
      final client = HttpClient(context: trust);
      addTearDown(() => client.close(force: true));
      routeConnections(
        client,
        proxy: proxy,
        bypass: bypassesProxy,
        context: trust,
        resolveHost: resolver.resolve,
        checkedAddress: resolver.connectAddress,
        connectAddress: (address, p) {
          connected.add((address.address, p));
          return Socket.startConnect(InternetAddress.loopbackIPv4, port);
        },
        connectRawAddress: (address, p) async {
          connected.add((address.address, p));
          final task = await RawSocket.startConnect(
            InternetAddress.loopbackIPv4,
            port,
          );
          return (socket: task.socket, cancel: task.cancel);
        },
        secure: (socket, {subscription, host, context}) {
          handshakeHosts.add(host);
          return RawSecureSocket.secure(
            socket,
            subscription: subscription,
            host: host,
            context: context,
          );
        },
      );
      return client;
    }

    Future<String> get(HttpClient client, String url) async {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      return await utf8.decodeStream(response);
    }

    test('plain http goes to the checked address, with the name as Host '
        '(also with a proxy, which it skips)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      answerHost(server);
      for (final proxy in [null, const ProxyAddress('127.0.0.1', 9)]) {
        connected.clear();
        final body = await real(
          () => get(
            pinnedClient(server.port, proxy: proxy),
            'http://$_tailnet:11434/api/tags',
          ),
        );
        expect(body, '$_tailnet:11434');
        expect(connected, [('fd7a:115c:a1e0::7', 11434)]);
      }
      // Looked up once (the second lookup was fresh), never resolved
      // by the connection.
      expect(lookups, [_tailnet]);
    });

    test('https goes to the checked address, with the name for SNI and the '
        'certificate', () async {
      final tls = await _certificateFor(_tailnet);
      if (tls == null) return markTestSkipped('openssl is not available');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls.server,
      );
      answerHost(server);

      final body = await real(
        () => get(
          pinnedClient(server.port, trust: tls.trust),
          'https://$_tailnet/api/tags',
        ),
      );

      expect(body, _tailnet);
      expect(connected, [('fd7a:115c:a1e0::7', 443)]);
      expect(handshakeHosts, [_tailnet]);
    });

    test('https refuses a certificate that is not for the name', () async {
      const other = 'pc.tail1234.ts.net';
      final tls = await _certificateFor(other);
      if (tls == null) return markTestSkipped('openssl is not available');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls.server,
      );
      answerHost(server);

      await expectLater(
        real(
          () => get(
            pinnedClient(server.port, trust: tls.trust),
            'https://$_tailnet/',
          ),
        ),
        throwsA(isA<HandshakeException>()),
      );
      expect(handshakeHosts, [_tailnet]);
    });

    test('a public name is not pinned', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      answerHost(server);
      // Resolved by the system: 127.0.0.1 has no lookup.
      final body = await real(
        () =>
            get(pinnedClient(server.port), 'http://127.0.0.1:${server.port}/'),
      );
      expect(body, '127.0.0.1:${server.port}');
      expect(connected, isEmpty);
    });

    test(
      'fails without a checked address, without resolving the name',
      () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        routeConnections(
          client,
          bypass: bypassesProxy,
          resolveHost: (host) async =>
              TailnetHosts.record(host, ['100.64.0.7']),
          checkedAddress: (_) => null,
          connectAddress: (address, port) {
            connected.add((address.address, port));
            throw StateError('not connected');
          },
        );

        await expectLater(
          real(() => client.getUrl(Uri.parse('http://$_tailnet/'))),
          throwsA(
            isA<SocketException>().having(
              (e) => e.message,
              'message',
              contains('No checked Tailscale address'),
            ),
          ),
        );
        expect(connected, isEmpty);
      },
    );

    test("is the app's client's default, also without a proxy", () async {
      await resolver.resolve(_tailnet);
      final client = createIoHttpClient(
        connectionTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(() => client.close(force: true));

      // The checked address is not reachable here; the name is never
      // resolved (it would fail as a host lookup).
      final error = await real(() async {
        try {
          await client.getUrl(Uri.parse('http://$_tailnet:11434/'));
        } on SocketException catch (error) {
          return error;
        }
        return null;
      });
      expect(error, isNotNull);
      expect(error!.message, isNot(contains('host lookup')));
      expect(lookups, [_tailnet]);
    });

    test('connectSecureAddress closes the connection when cancelled during '
        'the handshake', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(silent);
      final closed = Completer<void>();
      silent.listen((socket) {
        socket.listen((_) {}, onDone: closed.complete, onError: (_) {});
      });

      final task = await real(
        () => connectSecureAddress(
          InternetAddress('fd7a:115c:a1e0::7'),
          _tailnet,
          443,
          connect: (address, port) async {
            connected.add((address.address, port));
            final task = await RawSocket.startConnect(
              InternetAddress.loopbackIPv4,
              silent.port,
            );
            return (socket: task.socket, cancel: task.cancel);
          },
        ),
      );
      final socket = task.socket;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      task.cancel();

      await expectLater(socket, throwsA(isA<SocketException>()));
      await closed.future.timeout(const Duration(seconds: 5));
      expect(connected, [('fd7a:115c:a1e0::7', 443)]);
    });
  });
}

/// Real sockets, whatever `HttpOverrides` the test binding installs.
class _RealHttp extends HttpOverrides;

/// A server context with a certificate for [name] made for this run, and
/// the client trust of it; null without openssl.
Future<({SecurityContext server, SecurityContext trust})?> _certificateFor(
  String name,
) async {
  final dir = await Directory.systemTemp.createTemp('mozhi_tailnet_tls');
  try {
    final key = '${dir.path}/key.pem';
    final cert = '${dir.path}/cert.pem';
    final ProcessResult made;
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
        '/CN=$name',
        '-addext',
        'subjectAltName=DNS:$name',
      ]);
    } on ProcessException {
      return null;
    }
    if (made.exitCode != 0) return null;
    return (
      server: SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key),
      trust: SecurityContext()..setTrustedCertificates(cert),
    );
  } finally {
    await dir.delete(recursive: true);
  }
}
