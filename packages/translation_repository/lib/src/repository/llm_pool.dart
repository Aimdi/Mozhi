import 'package:llm_api/llm_api.dart';
import 'package:translation_repository/src/models/models.dart';

/// Creates a client for one LLM endpoint.
typedef LlmClientBuilder = LlmClient Function(LlmEndpoint endpoint);

/// Caches one [LlmClient] per AI provider, keyed by the provider id and the
/// parts of its configuration that affect the connection (protocol, base
/// URL, API key, headers). A client is replaced (and the old one closed)
/// when that configuration changes.
class LlmPool {
  new(this._builder);

  final LlmClientBuilder _builder;
  final Map<String, ({String key, LlmClient client})> _clients = {};

  /// The cached client for [config], created on first use.
  LlmClient clientFor(AiProviderConfig config) {
    final key = connectionKey(config);
    final cached = _clients[config.id];
    if (cached != null && cached.key == key) return cached.client;
    cached?.client.close();
    final client = _builder(config.toEndpoint());
    _clients[config.id] = (key: key, client: client);
    return client;
  }

  /// Closes clients of providers that were removed or whose connection
  /// settings changed.
  void update(List<AiProviderConfig> providers) {
    final keys = {
      for (final provider in providers) provider.id: connectionKey(provider),
    };
    _clients.removeWhere((id, entry) {
      if (keys[id] == entry.key) return false;
      entry.client.close();
      return true;
    });
  }

  /// Runs [action] with a fresh, uncached client for [config] (e.g. a
  /// provider that is still being edited) and closes it afterwards.
  Future<T> withTemporaryClient<T>(
    AiProviderConfig config,
    Future<T> Function(LlmClient client) action,
  ) async {
    final client = _builder(config.toEndpoint());
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }

  /// Closes every cached client.
  void dispose() {
    for (final entry in _clients.values) {
      entry.client.close();
    }
    _clients.clear();
  }

  /// Identifies the connection settings of [config].
  static String connectionKey(AiProviderConfig config) {
    final headers = [
      for (final MapEntry(:key, :value) in config.headers.entries)
        '$key:$value',
    ]..sort();
    return [
      config.provider.name,
      config.baseUrl,
      config.apiKey ?? '',
      ...headers,
    ].join('\u0000');
  }
}
