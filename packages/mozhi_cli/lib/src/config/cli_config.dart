import 'package:translation_repository/translation_repository.dart';

/// An AI provider as stored in the configuration file.
///
/// Unlike [AiProviderConfig.toJson], the stored JSON keeps the API key (the
/// file is only readable by its owner), or the name of an environment
/// variable holding it ([apiKeyEnv]).
class ProviderEntry {
  const new(this.config, {this.apiKeyEnv});

  /// Throws [FormatException] when `id` is missing.
  factory fromJson(Map<String, dynamic> json) {
    final config = AiProviderConfig.fromJson(json);
    final apiKey = json['apiKey'];
    final apiKeyEnv = json['apiKeyEnv'];
    return ProviderEntry(
      apiKey is String && apiKey.isNotEmpty
          ? config.copyWith(apiKey: apiKey)
          : config,
      apiKeyEnv: apiKeyEnv is String && apiKeyEnv.isNotEmpty ? apiKeyEnv : null,
    );
  }

  /// The provider settings, including a stored API key.
  final AiProviderConfig config;

  /// Environment variable read for the API key at run time.
  final String? apiKeyEnv;

  String get id => config.id;
  String get name => config.name;

  /// Where the API key comes from, for display (`stored`, `$VAR`, `none`).
  String get keySource => apiKeyEnv != null
      ? '\$$apiKeyEnv'
      : (config.apiKey?.isNotEmpty ?? false)
      ? 'stored'
      : 'none';

  /// The configuration with the API key taken from [environment] when
  /// [apiKeyEnv] is set (an unset variable falls back to a stored key).
  AiProviderConfig resolve(Map<String, String> environment) {
    final fromEnv = apiKeyEnv == null ? null : environment[apiKeyEnv];
    if (fromEnv == null || fromEnv.trim().isEmpty) return config;
    return config.copyWith(apiKey: fromEnv.trim());
  }

  Map<String, dynamic> toJson() => {
    ...config.toJson(),
    if (config.apiKey?.isNotEmpty ?? false) 'apiKey': config.apiKey,
    'apiKeyEnv': ?apiKeyEnv,
  };
}

/// Keys accepted by `mozhi config set` / `mozhi config unset`.
enum ConfigKey {
  instance('Mozhi instance URL used for translations'),
  engine('Default engine, e.g. google, deepl or ai:<provider>'),
  source('Default source language (default: auto)'),
  target('Default target language (default: en)');

  const new(this.description);

  final String description;

  static ConfigKey? tryParse(String name) {
    final key = name.trim().toLowerCase();
    for (final value in values) {
      if (value.name == key) return value;
    }
    return switch (key) {
      'from' => ConfigKey.source,
      'to' => ConfigKey.target,
      'url' || 'instance-url' => ConfigKey.instance,
      _ => null,
    };
  }
}

/// The contents of `config.json`.
class CliConfig {
  const new({
    this.instance,
    this.engine,
    this.source,
    this.target,
    this.providers = const [],
  });

  /// Tolerant: unknown keys and wrongly typed values are ignored. Throws
  /// [FormatException] for providers without an id.
  factory fromJson(Map<String, dynamic> json) {
    String? string(String key) {
      final value = json[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final providers = json['providers'];
    return CliConfig(
      instance: string('instance'),
      engine: string('engine'),
      source: string('source'),
      target: string('target'),
      providers: providers is List
          ? [
              for (final provider in providers)
                if (provider is Map<String, dynamic>)
                  ProviderEntry.fromJson(provider),
            ]
          : const [],
    );
  }

  /// Default Mozhi instance URL (normalised). When null the public
  /// instances are used, with failover.
  final String? instance;

  /// Default engine spec, e.g. `mozhi:google` or `ai:claude`.
  final String? engine;

  /// Default source language code or name.
  final String? source;

  /// Default target language code or name.
  final String? target;
  final List<ProviderEntry> providers;

  /// Engine used when none is given.
  static const defaultEngine = 'mozhi:google';

  /// Target language used when none is given or configured.
  static const defaultTarget = 'en';

  String? valueOf(ConfigKey key) => switch (key) {
    ConfigKey.instance => instance,
    ConfigKey.engine => engine,
    ConfigKey.source => source,
    ConfigKey.target => target,
  };

  /// Returns a copy with [key] set to [value] (null clears it).
  CliConfig withValue(ConfigKey key, String? value) => CliConfig(
    instance: key == ConfigKey.instance ? value : instance,
    engine: key == ConfigKey.engine ? value : engine,
    source: key == ConfigKey.source ? value : source,
    target: key == ConfigKey.target ? value : target,
    providers: providers,
  );

  CliConfig withProviders(List<ProviderEntry> providers) => CliConfig(
    instance: instance,
    engine: engine,
    source: source,
    target: target,
    providers: List.unmodifiable(providers),
  );

  /// Finds a provider by id or (case-insensitive) name.
  ProviderEntry? findProvider(String idOrName) {
    final key = idOrName.trim().toLowerCase();
    for (final provider in providers) {
      if (provider.id.toLowerCase() == key) return provider;
    }
    for (final provider in providers) {
      if (provider.name.toLowerCase() == key) return provider;
    }
    return null;
  }

  /// Whether any provider has an API key stored in the file.
  bool get hasSecrets =>
      providers.any((p) => p.config.apiKey?.isNotEmpty ?? false);

  Map<String, dynamic> toJson() => {
    'instance': ?instance,
    'engine': ?engine,
    'source': ?source,
    'target': ?target,
    if (providers.isNotEmpty)
      'providers': [for (final provider in providers) provider.toJson()],
  };
}
