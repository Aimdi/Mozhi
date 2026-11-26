import 'package:mozhi_cli/src/config/cli_config.dart';
import 'package:mozhi_cli/src/errors.dart';
import 'package:translation_repository/translation_repository.dart';

/// Engines every Mozhi instance can proxy (id -> display name).
const mozhiEngineNames = <String, String>{
  'google': 'Google',
  'deepl': 'DeepL',
  'yandex': 'Yandex',
  'reverso': 'Reverso',
  'libre': 'LibreTranslate',
  'mymemory': 'MyMemory',
  'duckduckgo': 'DuckDuckGo',
};

const _mozhiAliases = <String, String>{
  'libretranslate': 'libre',
  'ddg': 'duckduckgo',
  'bing': 'duckduckgo',
};

/// The engine for an AI [provider].
TranslationEngine aiEngine(AiProviderConfig provider) => TranslationEngine(
  id: 'ai:${provider.id}',
  kind: EngineKind.ai,
  name: provider.name,
  subtitle: provider.model,
  providerId: provider.id,
  isLocal: provider.isLocal,
);

/// The engine for a direct machine translation [provider] (DeepL API or
/// LibreTranslate).
TranslationEngine mtEngine(AiProviderConfig provider) => TranslationEngine(
  id: 'mt:${provider.id}',
  kind: EngineKind.mt,
  name: provider.name,
  subtitle: provider.service == MtService.deepl
      ? 'DeepL API'
      : (provider.baseUrl.isEmpty ? 'LibreTranslate' : provider.baseUrl),
  providerId: provider.id,
  isLocal: provider.isLocal,
  mtService: provider.service,
);

/// The [TranslationEngine] for [provider] (`ai:<id>` or `mt:<id>`).
TranslationEngine providerEngine(AiProviderConfig provider) =>
    provider.isMtService ? mtEngine(provider) : aiEngine(provider);

/// Resolves an engine spec given on the command line or in the config:
///
/// * `mozhi:<engine>` or a bare Mozhi engine (`google`, `deepl`, ...).
/// * `ai:<provider>` (id or name) or `ai` (first enabled AI provider).
/// * `mt:<provider>` (id or name) or `mt` (first enabled MT provider).
/// * A bare configured provider id or name (AI or MT).
///
/// Unknown bare names are treated as Mozhi engines (instances can offer
/// engines this tool does not know about).
TranslationEngine resolveEngine(String spec, List<AiProviderConfig> providers) {
  final trimmed = spec.trim();
  final lower = trimmed.toLowerCase();
  if (trimmed.isEmpty) {
    throw const CliException.usage('The engine must not be empty.');
  }
  if (lower == 'ai') {
    final provider = providers
        .where((p) => p.enabled && !p.isMtService)
        .firstOrNull;
    if (provider == null) throw _noProviders();
    return aiEngine(provider);
  }
  if (lower == 'mt') {
    final provider = providers
        .where((p) => p.enabled && p.isMtService)
        .firstOrNull;
    if (provider == null) throw _noMtProviders();
    return mtEngine(provider);
  }
  if (lower.startsWith('ai:')) {
    final provider = _findProvider(trimmed.substring(3), providers);
    if (provider.isMtService) {
      throw CliException.usage(
        '"${provider.name}" is a direct MT provider, not an AI provider.',
        hint: 'Use --engine mt:${provider.id}',
      );
    }
    return aiEngine(provider);
  }
  if (lower.startsWith('mt:')) {
    final mtProviders = [
      for (final p in providers)
        if (p.isMtService) p,
    ];
    final provider = _matchProvider(trimmed.substring(3), mtProviders);
    if (provider != null) return mtEngine(provider);
    final other = _matchProvider(trimmed.substring(3), providers);
    if (other != null) {
      throw CliException.usage(
        '"${other.name}" is an AI provider, not an MT provider.',
        hint: 'Use --engine ai:${other.id}',
      );
    }
    if (mtProviders.isEmpty) throw _noMtProviders();
    throw CliException.usage(
      'Unknown MT provider "${trimmed.substring(3).trim()}".',
      hint:
          'Configured MT providers: '
          '${mtProviders.map((p) => p.id).join(', ')}.',
    );
  }
  if (lower.startsWith('mozhi:')) {
    return _mozhiEngine(lower.substring('mozhi:'.length));
  }
  final provider = _matchProvider(trimmed, providers);
  if (provider != null) return providerEngine(provider);
  return _mozhiEngine(lower);
}

/// Resolves an AI provider for AI-only commands (proofreading, dictionary):
/// `--engine` if given, else the configured default if it is an AI provider,
/// else the first enabled AI provider.
TranslationEngine resolveAiEngine(
  String? spec,
  CliConfig config,
  List<AiProviderConfig> providers, {
  required String feature,
}) {
  if (spec != null) {
    final engine = resolveEngine(spec, providers);
    if (!engine.isAi) {
      throw CliException.usage(
        '$feature needs an AI provider, not ${engine.name}.',
        hint: 'Use --engine ai or --engine ai:<provider>.',
      );
    }
    return engine;
  }
  final configured = config.engine;
  if (configured != null) {
    try {
      final engine = resolveEngine(configured, providers);
      if (engine.isAi) return engine;
    } on CliException {
      // Fall through to the first configured AI provider.
    }
  }
  final first = providers.where((p) => p.enabled && !p.isMtService).firstOrNull;
  if (first == null) {
    throw CliException.usage(
      '$feature needs an AI provider and none is configured.',
      hint:
          'Add one, e.g.: mozhi config providers add --preset ollama '
          '--model gemma3',
    );
  }
  return aiEngine(first);
}

TranslationEngine _mozhiEngine(String name) {
  final id = _mozhiAliases[name.trim()] ?? name.trim();
  if (id.isEmpty || !RegExp(r'^[a-z0-9_-]+$').hasMatch(id)) {
    throw CliException.usage(
      'Invalid Mozhi engine "$name".',
      hint: 'Known engines: ${mozhiEngineNames.keys.join(', ')}.',
    );
  }
  return TranslationEngine.mozhi(id, mozhiEngineNames[id] ?? id);
}

AiProviderConfig? _matchProvider(
  String idOrName,
  List<AiProviderConfig> providers,
) {
  final key = idOrName.trim().toLowerCase();
  return providers.where((p) => p.id.toLowerCase() == key).firstOrNull ??
      providers.where((p) => p.name.toLowerCase() == key).firstOrNull;
}

AiProviderConfig _findProvider(
  String idOrName,
  List<AiProviderConfig> providers,
) {
  final provider = _matchProvider(idOrName, providers);
  if (provider != null) return provider;
  if (providers.isEmpty) throw _noProviders();
  throw CliException.usage(
    'Unknown AI provider "${idOrName.trim()}".',
    hint:
        'Configured providers: '
        '${providers.map((p) => p.id).join(', ')}.',
  );
}

CliException _noProviders() => const CliException.usage(
  'No AI provider is configured.',
  hint:
      'Add one, e.g.: mozhi config providers add --preset ollama '
      '--model gemma3',
);

CliException _noMtProviders() => const CliException.usage(
  'No direct MT provider is configured.',
  hint:
      'Add one, e.g.: mozhi config providers add --preset deepl '
      '--api-key-env DEEPL_API_KEY',
);

/// Resolves a language given as a code (`fr`, `pt-BR`) or English name
/// (`French`, `chinese (traditional)`).
///
/// `auto` is only accepted when [allowAuto]. Unknown input becomes a
/// custom free-form language when [allowCustom] (AI targets such as
/// "Pirate speak"), else it is kept as a raw engine-specific code.
Language resolveLanguage(
  String input, {
  bool allowAuto = false,
  bool allowCustom = false,
}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const CliException.usage('The language must not be empty.');
  }
  if (trimmed.toLowerCase() == 'auto') {
    if (allowAuto) return Language.auto;
    throw const CliException.usage(
      '"auto" can only be used as the source language.',
    );
  }
  final known =
      LanguageCatalog.byCode(trimmed) ?? LanguageCatalog.byName(trimmed);
  if (known != null) return known;
  if (allowCustom) return Language.custom(trimmed);
  return Language(code: trimmed, name: trimmed);
}

/// Parses `term=translation` glossary entries (`term=>translation` works
/// too, and `term:translation` when there is no `=`).
Map<String, String> parseGlossary(Iterable<String> entries) {
  final glossary = <String, String>{};
  for (final entry in entries) {
    final separator =
        RegExp('=>?').firstMatch(entry) ?? RegExp(':').firstMatch(entry);
    final term = separator == null
        ? ''
        : entry.substring(0, separator.start).trim();
    final translation = separator == null
        ? ''
        : entry.substring(separator.end).trim();
    if (term.isEmpty || translation.isEmpty) {
      throw CliException.usage(
        'Invalid glossary entry "$entry".',
        hint: 'Use term=translation, e.g. --glossary "cloud=nuage".',
      );
    }
    glossary[term] = translation;
  }
  return glossary;
}

/// Matches an enum value by name ignoring case, `-` and `_`
/// (`prefer-more` -> `preferMore`), plus [aliases].
T parseChoice<T extends Enum>(
  String option,
  String value,
  List<T> values, {
  Map<String, T> aliases = const {},
}) {
  String key(String s) => s.toLowerCase().replaceAll(RegExp('[-_ ]'), '');
  final wanted = key(value);
  for (final candidate in values) {
    if (key(candidate.name) == wanted) return candidate;
  }
  for (final MapEntry(key: alias, :value) in aliases.entries) {
    if (key(alias) == wanted) return value;
  }
  throw CliException.usage(
    'Invalid value "$value" for --$option.',
    hint: 'Allowed: ${values.map((v) => kebabCase(v.name)).join(', ')}.',
  );
}

/// `preferMore` -> `prefer-more`.
String kebabCase(String name) => name.replaceAllMapped(
  RegExp('[A-Z]'),
  (match) => '-${match[0]!.toLowerCase()}',
);
