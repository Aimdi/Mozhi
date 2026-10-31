@TestOn('vm')
library;

import 'dart:async';
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

void main() {
  late List<String> lookups;
  late TailnetResolver resolver;

  Future<List<String>> lookup(String host) async {
    lookups.add(host);
    final addresses = _addresses[host];
    if (addresses == null) throw SocketException('No address for $host');
    return addresses;
  }

  setUp(() {
    lookups = [];
    resolver = TailnetResolver(lookup: lookup);
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
          () => client.getUrl(Uri.parse('https://$_tailnet/')),
          _RealHttp(),
        ),
        throwsA(isA<SocketException>()),
      );

      expect(decided, [(_tailnet, true)]);
      expect(lookups, [_tailnet]);
    });
  });
}

/// Real sockets, whatever `HttpOverrides` the test binding installs.
class _RealHttp extends HttpOverrides;
