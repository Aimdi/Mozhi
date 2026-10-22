import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('isCleartextAllowed', () {
    for (final url in [
      'http://localhost:3000',
      'http://127.0.0.1',
      'http://192.168.1.10:3000/mozhi',
      'http://10.0.0.2',
      'http://[fd00::1]:8080',
      'http://raspberrypi',
      'http://mozhi.lan',
      'http://nas.local',
      'http://abc.onion',
      'http://abc.b32.i2p',
      'https://mozhi.example.com',
      'https://8.8.8.8',
    ]) {
      test(
        'allows $url',
        () => expect(isCleartextAllowed(Uri.parse(url)), true),
      );
    }

    for (final url in [
      'http://mozhi.example.com',
      'http://8.8.8.8',
      'http://[2001:db8::1]',
      'HTTP://Mozhi.Example.com',
    ]) {
      test('refuses $url', () {
        expect(isCleartextAllowed(Uri.parse(url)), isFalse);
      });
    }
  });

  test('isHiddenServiceHost', () {
    expect(isHiddenServiceHost('abc.onion'), isTrue);
    expect(isHiddenServiceHost(' Mozhi.ABC.Onion. '), isTrue);
    expect(isHiddenServiceHost('abc.b32.i2p'), isTrue);
    expect(isHiddenServiceHost('onion.example'), isFalse);
    expect(isHiddenServiceHost('localhost'), isFalse);
  });

  group('NetworkPolicy', () {
    const direct = NetworkPolicy(hasProxy: false);
    const proxied = NetworkPolicy(hasProxy: true);
    const browser = NetworkPolicy(
      hasProxy: false,
      hiddenServicesNeedProxy: false,
    );

    test('lets https and private http through', () {
      for (final url in [
        'https://mozhi.example/api/translate',
        'http://192.168.1.2:3000/api/engines',
      ]) {
        expect(() => direct.check(Uri.parse(url)), returnsNormally);
      }
    });

    test('refuses plain http to a public host without its query', () {
      expect(
        () => direct.check(
          Uri.parse('http://me:pw@mozhi.example/api/tts?text=secret#x'),
        ),
        throwsA(
          isA<CleartextRefusedException>()
              .having(
                (e) => e.message,
                'message',
                startsWith('Use https for public servers'),
              )
              .having(
                (e) => e.uri.toString(),
                'uri',
                'http://mozhi.example/api/tts',
              ),
        ),
      );
    });

    test('hidden services need a proxy', () {
      final onion = Uri.parse('http://abc.onion/api/engines');

      expect(
        () => direct.check(onion),
        throwsA(
          isA<ProxyRequiredException>().having(
            (e) => e.message,
            'message',
            startsWith(ProxyRequiredException.marker),
          ),
        ),
      );
      expect(
        () => direct.check(Uri.parse('https://abc.b32.i2p')),
        throwsA(isA<ProxyRequiredException>()),
      );
      expect(() => proxied.check(onion), returnsNormally);
      expect(() => browser.check(onion), returnsNormally);
    });

    test('equality', () {
      expect(direct, const NetworkPolicy(hasProxy: false));
      expect(direct.hashCode, const NetworkPolicy(hasProxy: false).hashCode);
      expect(direct, isNot(proxied));
      expect(direct, isNot(browser));
    });
  });

  group(WebsiteHttpClient, () {
    late List<http.BaseRequest> sent;
    late bool closed;

    WebsiteHttpClient client({bool hasProxy = false}) => WebsiteHttpClient(
      _ForwardingClient(
        MockClient((request) async {
          sent.add(request);
          return http.Response('ok', 200);
        }),
        onClose: () => closed = true,
      ),
      policy: NetworkPolicy(hasProxy: hasProxy),
    );

    setUp(() {
      sent = [];
      closed = false;
    });

    test(
      'fetches plain http pages and strips cookies and the referer',
      () async {
        await client().get(
          Uri.parse('http://example.org/page'),
          headers: {'Cookie': 'a=1', 'Referer': 'https://x/', 'Accept': '*/*'},
        );

        expect(sent.single.url, Uri.parse('http://example.org/page'));
        expect(sent.single.headers, {'Accept': '*/*'});
      },
    );

    test('needs a proxy for .onion and .i2p pages', () async {
      await expectLater(
        client().get(Uri.parse('http://abc.onion/?q=secret')),
        throwsA(
          isA<ProxyRequiredException>().having(
            (e) => e.uri.toString(),
            'uri',
            'http://abc.onion/',
          ),
        ),
      );
      expect(sent, isEmpty);

      await client(hasProxy: true).get(Uri.parse('http://abc.onion/'));
      expect(sent, hasLength(1));
    });

    test('leaves closing to the owner of the connection', () {
      client().close();

      expect(closed, isFalse);
    });
  });

  group('BackendHttpClient', () {
    late List<http.BaseRequest> sent;
    late BackendHttpClient client;

    setUp(() {
      sent = [];
      client = BackendHttpClient(
        MockClient((request) async {
          sent.add(request);
          return http.Response('ok', 200);
        }),
        policy: const NetworkPolicy(hasProxy: false),
      );
    });

    test('strips cookies and the referer', () async {
      await client.get(
        Uri.parse('https://mozhi.example/api/engines'),
        headers: {
          'Cookie': 'session=1',
          'cookie2': 'x',
          'REFERER': 'https://app.example/',
          'Authorization': 'Bearer k',
        },
      );

      expect(sent.single.headers, {'Authorization': 'Bearer k'});
    });

    test('refuses before anything is sent', () async {
      await expectLater(
        client.get(Uri.parse('http://mozhi.example/api/engines')),
        throwsA(isA<CleartextRefusedException>()),
      );
      await expectLater(
        client.get(Uri.parse('http://abc.onion/api/engines')),
        throwsA(isA<ProxyRequiredException>()),
      );
      expect(sent, isEmpty);
    });

    test('closes the wrapped client', () {
      var closed = false;
      final inner = _ClosingClient(() => closed = true);

      BackendHttpClient(
        inner,
        policy: const NetworkPolicy(hasProxy: false),
      ).close();

      expect(closed, isTrue);
    });
  });

  group('NetworkPolicyError.of', () {
    final refusing = BackendHttpClient(
      MockClient((_) async => http.Response('', 200)),
      policy: const NetworkPolicy(hasProxy: false),
    );
    final publicHttp = Uri.parse('http://mozhi.example');

    test('recognises the raw exceptions', () {
      expect(
        NetworkPolicyError.of(CleartextRefusedException(null)),
        NetworkPolicyError.cleartext,
      );
      expect(
        NetworkPolicyError.of(ProxyRequiredException(null)),
        NetworkPolicyError.proxyRequired,
      );
      expect(
        NetworkPolicyError.of(InvalidProxyException(null)),
        NetworkPolicyError.invalidProxy,
      );
      for (final refused in [
        RedirectRefusedException.downgrade(null),
        RedirectRefusedException.intoPrivateNetwork(null),
        RedirectRefusedException.unsupported(null),
      ]) {
        expect(
          NetworkPolicyError.of(refused),
          NetworkPolicyError.redirectRefused,
        );
      }
      expect(NetworkPolicyError.of(null), isNull);
      expect(NetworkPolicyError.of(StateError('x')), isNull);
      expect(
        NetworkPolicyError.of(http.ClientException('Connection refused')),
        isNull,
      );
    });

    test('recognises what the Mozhi client made of it', () async {
      final mozhi = MozhiApiClient(baseUrl: publicHttp, httpClient: refusing);

      final error = await mozhi.getEngines().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      expect(error, isA<MozhiApiException>());
      expect(NetworkPolicyError.of(error), NetworkPolicyError.cleartext);
    });

    test('recognises what an LLM client made of it', () async {
      final llm = LlmClient(
        LlmEndpoint(
          provider: LlmProvider.ollama,
          baseUrl: Uri.parse('http://llm.example:11434'),
        ),
        httpClient: refusing,
      );

      final error = await llm.listModels().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );

      expect(error, isA<LlmApiException>());
      expect(NetworkPolicyError.of(error), NetworkPolicyError.cleartext);
    });

    test('recognises what a machine translation client made of it', () async {
      final libre = LibreTranslateClient(
        baseUrl: publicHttp,
        httpClient: BackendHttpClient(
          MockClient((_) async => http.Response('', 200)),
          policy: const NetworkPolicy(hasProxy: false),
        ),
      );

      final error = await libre
          .translate(text: 'x', target: 'de')
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect(error, isA<MtApiException>());
      expect(NetworkPolicyError.of(error), NetworkPolicyError.cleartext);
    });

    test('recognises other wrapped errors by their text', () {
      expect(
        NetworkPolicyError.of(Exception(ProxyRequiredException.defaultMessage)),
        NetworkPolicyError.proxyRequired,
      );
    });
  });

  test('describeNetworkPolicyError', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    expect(
      describeNetworkPolicyError(l10n, CleartextRefusedException(null)),
      allOf(
        startsWith('Use https for public servers'),
        l10n.commonErrorCleartextRefused,
      ),
    );
    expect(
      describeNetworkPolicyError(l10n, ProxyRequiredException(null)),
      l10n.commonErrorProxyRequired,
    );
    expect(
      describeNetworkPolicyError(l10n, InvalidProxyException(null)),
      l10n.commonErrorInvalidProxy,
    );
    expect(
      describeNetworkPolicyError(
        l10n,
        RedirectRefusedException.intoPrivateNetwork(null),
      ),
      l10n.commonErrorRedirectRefused,
    );
    expect(describeNetworkPolicyError(l10n, StateError('x')), isNull);
  });
}

class _ClosingClient extends http.BaseClient {
  new(this._onClose);

  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() => _onClose();
}

/// Hands requests to an inner client and reports [close].
class _ForwardingClient extends http.BaseClient {
  new(this._inner, {required this.onClose});

  final http.Client _inner;
  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => onClose();
}
