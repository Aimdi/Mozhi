import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/network/mozhi_instance_checker.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

/// The network setup of this run of the app: the proxy read from the
/// settings at startup (`AppSettings.httpProxy`; a change applies after a
/// restart), the [NetworkPolicy], the one HTTP [client] every translation
/// backend shares, and the [ledger] of the requests made through it. Its
/// factories create the backend clients for the `TranslationRepository`.
///
/// `bootstrap` creates it and makes it [current]; widgets that talk to a
/// backend outside the repository (the instance checks) use [current].
class NetworkSession {
  /// [proxy] is `host:port` (see [ProxyAddress.parse]); it is ignored in a
  /// browser. [httpClient] replaces the platform client from
  /// [createHttpClient] (tests); either is wrapped in an
  /// [EgressRecordingClient] that records every request in [ledger]
  /// (default: a new, empty one), and that in a [BackendHttpClient] with
  /// [policy].
  new({String? proxy, http.Client? httpClient, EgressLedger? ledger})
    : proxy = kIsWeb ? null : _blankToNull(proxy),
      _platformClient = httpClient,
      ledger = ledger ?? EgressLedger();

  /// The session of this run (see `bootstrap`). Until one is set, a
  /// session without a proxy.
  static NetworkSession current = NetworkSession();

  /// The proxy setting this session uses, or null for direct connections.
  final String? proxy;

  /// The requests this session sent (in memory only; see [EgressLedger]):
  /// every backend, the web page translator and the model downloads (which
  /// use [current]'s [client]). Requests the [policy] refuses are not sent
  /// and not recorded.
  final EgressLedger ledger;

  final http.Client? _platformClient;
  bool _clientCreated = false;

  /// Whether requests go through a proxy.
  bool get hasProxy => proxy != null;

  /// The rules every backend request follows. `.onion` and `.i2p` need a
  /// proxy, except in a browser (which may reach them itself).
  NetworkPolicy get policy =>
      NetworkPolicy(hasProxy: hasProxy, hiddenServicesNeedProxy: !kIsWeb);

  /// The platform client (with the proxy) under [client] and [webClient];
  /// created on first use.
  late final http.Client _platform = () {
    _clientCreated = true;
    return _platformClient ?? createHttpClient(proxy: proxy);
  }();

  /// Whether a request to [host] goes through the [proxy]: all of them but
  /// those to this device and the private network, which a proxy such as
  /// Tor could not reach (the platform client's `bypassesProxy`; `.onion`
  /// and `.i2p` always use it).
  bool usesProxyFor(String host) {
    if (!hasProxy) return false;
    final name = host.toLowerCase();
    final bypassed =
        DataDestination.isPrivateHost(name) &&
        !name.endsWith('.onion') &&
        !name.endsWith('.i2p');
    return !bypassed;
  }

  /// The client of every backend; created on first use.
  late final http.Client client = BackendHttpClient(
    EgressRecordingClient(_platform, ledger: ledger, viaProxy: usesProxyFor),
    policy: policy,
  );

  /// The client of the web page translator, for pages the user asks for:
  /// the same connection and proxy as [client], so a page is never fetched
  /// around the proxy, but without the backends' https rule (a page may be
  /// plain http). See [WebsiteHttpClient]. Closing it does nothing; [close]
  /// closes the connection.
  late final http.Client webClient = WebsiteHttpClient(
    EgressRecordingClient(
      _platform,
      ledger: ledger,
      purpose: EgressPurpose.webPage,
      viaProxy: usesProxyFor,
    ),
    policy: policy,
  );

  /// Session-long Mozhi instance checks (see [MozhiInstanceChecker]).
  late final MozhiInstanceChecker instanceChecker = MozhiInstanceChecker(
    (baseUrl, timeout) => mozhiClient(baseUrl, timeout: timeout),
  );

  /// A Mozhi client for [baseUrl] on [client].
  MozhiApiClient mozhiClient(
    Uri baseUrl, {
    Duration timeout = const Duration(seconds: 30),
  }) => MozhiApiClient(baseUrl: baseUrl, httpClient: client, timeout: timeout);

  /// An LLM client for [endpoint] on [client].
  LlmClient llmClient(LlmEndpoint endpoint) =>
      LlmClient(endpoint, httpClient: client);

  /// The DeepL client of a [MtService.deepl] provider on [client]: its API
  /// key, and its base URL (`https://` added when it has no scheme) or the
  /// official API chosen by the key.
  DeeplClient deeplClient(AiProviderConfig config) {
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return DeeplClient(
      authKey: config.apiKey ?? '',
      baseUrl: base.isEmpty
          ? null
          : Uri.parse(base.contains('://') ? base : 'https://$base'),
      httpClient: client,
    );
  }

  /// The LibreTranslate client of a [MtService.libreTranslate] provider on
  /// [client] (normalised base URL, API key).
  LibreTranslateClient libreClient(AiProviderConfig config) =>
      LibreTranslateClient(
        baseUrl: LibreTranslateClient.normalizeBaseUrl(config.baseUrl),
        apiKey: config.apiKey,
        httpClient: client,
      );

  /// Closes [client] and [webClient] (when one was used) and the
  /// [instanceChecker]'s change stream.
  Future<void> close() async {
    if (_clientCreated) _platform.close();
    await instanceChecker.dispose();
  }

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
