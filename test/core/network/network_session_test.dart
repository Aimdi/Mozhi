import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/core/network/http_client_factory_io.dart'
    show bypassesProxy;
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

class _RecordingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  bool closed = false;

  late final _inner = MockClient((request) async {
    requests.add(request);
    return switch (request.url.path) {
      '/api/engines' => http.Response('{"google":"Google"}', 200),
      '/v2/usage' => http.Response('{"character_count":1}', 200),
      '/frontend/settings' => http.Response('{}', 200),
      '/api/tags' => http.Response(jsonEncode({'models': <Object>[]}), 200),
      _ => http.Response('{}', 200),
    };
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => closed = true;
}

AiProviderConfig _service(MtService service, String baseUrl) =>
    AiProviderConfig(
      id: 'p',
      name: 'P',
      provider: LlmProvider.openAiCompatible,
      baseUrl: baseUrl,
      model: '',
      apiKey: 'key',
      service: service,
    );

void main() {
  late _RecordingClient platform;

  setUp(() => platform = _RecordingClient());

  group('NetworkSession', () {
    test('keeps a set proxy and ignores a blank one', () {
      expect(NetworkSession(proxy: ' 127.0.0.1:8118 ').proxy, '127.0.0.1:8118');
      expect(NetworkSession(proxy: ' 127.0.0.1:8118 ').hasProxy, isTrue);
      expect(NetworkSession(proxy: '  ').proxy, isNull);
      expect(NetworkSession().hasProxy, isFalse);
    });

    test('its policy follows the proxy', () {
      expect(
        NetworkSession(proxy: '127.0.0.1:8118').policy,
        const NetworkPolicy(hasProxy: true),
      );
      expect(NetworkSession().policy, const NetworkPolicy(hasProxy: false));
    });

    test('wraps the platform client in the policy', () async {
      final session = NetworkSession(httpClient: platform);

      expect(session.client, isA<BackendHttpClient>());
      await expectLater(
        session.client.get(Uri.parse('http://abc.onion/')),
        throwsA(isA<ProxyRequiredException>()),
      );
      await session.client.get(
        Uri.parse('https://mozhi.example/'),
        headers: {'cookie': 'x'},
      );
      expect(platform.requests.single.headers, isEmpty);
    });

    test('fetches web pages over the same connection', () async {
      final session = NetworkSession(httpClient: platform);

      expect(session.webClient, isA<WebsiteHttpClient>());
      await session.webClient.get(Uri.parse('http://example.org/'));
      expect(platform.requests.single.url, Uri.parse('http://example.org/'));
      await expectLater(
        session.webClient.get(Uri.parse('http://abc.onion/')),
        throwsA(isA<ProxyRequiredException>()),
      );
      await session.close();
      expect(platform.closed, isTrue);
    });

    test('creates a platform client lazily', () async {
      final session = NetworkSession();

      expect(session.client, isA<BackendHttpClient>());
      await session.close();
    });

    test('backend clients share the client', () async {
      final session = NetworkSession(httpClient: platform);

      await session
          .mozhiClient(Uri.parse('https://mozhi.example'))
          .getEngines();
      await session
          .llmClient(
            LlmEndpoint(
              provider: LlmProvider.ollama,
              baseUrl: Uri.parse('http://localhost:11434'),
            ),
          )
          .listModels();
      await session
          .deeplClient(_service(MtService.deepl, ' api.deepl.example/ '))
          .usage();
      await session
          .libreClient(_service(MtService.libreTranslate, 'lt.example'))
          .settings();

      expect(platform.requests.map((r) => r.url.toString()), [
        'https://mozhi.example/api/engines',
        'http://localhost:11434/api/tags',
        'https://api.deepl.example/v2/usage',
        'https://lt.example/frontend/settings',
      ]);
    });

    test('a DeepL client without a URL uses the official API', () {
      final session = NetworkSession(httpClient: platform);

      expect(
        session.deeplClient(_service(MtService.deepl, '')).baseUrl,
        DeeplClient.proBaseUrl,
      );
      expect(
        session
            .deeplClient(_service(MtService.deepl, 'http://192.168.1.2:8080'))
            .baseUrl
            .toString(),
        'http://192.168.1.2:8080',
      );
    });

    test('the instance checker uses the client with its timeout', () async {
      final session = NetworkSession(httpClient: platform);

      final health = await session.instanceChecker.check(
        'https://mozhi.example',
      );

      expect(health, isA<InstanceOnline>());
      expect(
        session.mozhiClient(Uri.parse('https://a.example')).timeout,
        MozhiApiClient.defaultTimeout,
      );
      expect(
        session
            .mozhiClient(
              Uri.parse('https://a.example'),
              timeout: const Duration(seconds: 3),
            )
            .timeout,
        const Duration(seconds: 3),
      );
      // Tor adds seconds to every request.
      expect(
        NetworkSession(
          proxy: '127.0.0.1:8118',
          httpClient: platform,
        ).mozhiClient(Uri.parse('https://a.example')).timeout,
        NetworkSession.proxyRequestTimeout,
      );
    });

    test('close closes only a client that was used', () async {
      await NetworkSession(httpClient: platform).close();
      expect(platform.closed, isFalse);

      final session = NetworkSession(httpClient: platform);
      expect(session.client, isNotNull);
      await session.close();
      expect(platform.closed, isTrue);
    });

    test('records what the backends and the web client send', () async {
      final ledger = EgressLedger();
      final session = NetworkSession(httpClient: platform, ledger: ledger);

      await session
          .mozhiClient(Uri.parse('https://mozhi.example'))
          .getEngines();
      await session.webClient.get(Uri.parse('http://example.org/page?q=1'));

      expect(session.ledger, same(ledger));
      final [engines, page] = ledger.entries;
      expect(engines.destination.host, 'mozhi.example');
      expect(engines.purpose, EgressPurpose.catalog);
      expect(engines.outcome, EgressOutcome.succeeded);
      expect(page.purpose, EgressPurpose.webPage);
      expect(page.destination.kind, EgressDestinationKind.website);
      expect(page.scheme, 'http');
    });

    test('does not record what the policy refuses (never sent)', () async {
      final session = NetworkSession(httpClient: platform);

      await expectLater(
        session.client.get(Uri.parse('http://public.example/')),
        throwsA(isA<CleartextRefusedException>()),
      );

      expect(session.ledger.entries, isEmpty);
      expect(platform.requests, isEmpty);
    });

    test('notes which requests use the proxy', () async {
      final direct = NetworkSession();
      expect(direct.usesProxyFor('mozhi.example'), isFalse);

      final proxied = NetworkSession(
        proxy: '127.0.0.1:8118',
        httpClient: platform,
      );
      expect(proxied.usesProxyFor('mozhi.example'), isTrue);
      expect(proxied.usesProxyFor('abc.ONION'), isTrue);
      expect(proxied.usesProxyFor('mozhi.i2p'), isTrue);
      expect(proxied.usesProxyFor('192.168.1.4'), isFalse);
      expect(proxied.usesProxyFor('localhost'), isFalse);

      // The same rule as the platform client's.
      for (final host in [
        'mozhi.example',
        'abc.onion',
        '10.0.0.2',
        'nas.local',
        '::1',
        'fd00::1',
      ]) {
        expect(proxied.usesProxyFor(host), !bypassesProxy(host), reason: host);
      }

      await proxied.client.get(Uri.parse('https://mozhi.example/api/version'));
      expect(proxied.ledger.entries.single.viaProxy, isTrue);
    });

    test('current can be replaced', () {
      final previous = NetworkSession.current;
      addTearDown(() => NetworkSession.current = previous);
      final session = NetworkSession(httpClient: platform);

      NetworkSession.current = session;

      expect(NetworkSession.current, same(session));
    });
  });
}
