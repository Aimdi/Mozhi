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

/// Resolves an engine spec given on the command line or in the config:
///
/// * `mozhi:<engine>` or a bare Mozhi engine (`google`, `deepl`, ...).
/// * `ai:<provider>` (id or name) or a bare provider id or name.
/// * `ai` alone: the first enabled AI provider.
///
/// Unknown bare names are treated as Mozhi engines (instances can offer
/// engines this tool does not know about).
TranslationEngine resolveEngine(
  String spec,
  List<AiProviderConfig> providers,
) {
  final trimmed = spec.trim();
  final lower = trimmed.toLowerCase();
  if (trimmed.isEmpty) {
    throw const CliException.usage('The engine must not be empty.');
  }
  if (lower == 'ai') {
    final provider = providers.where((p) => p.enabled).firstOrNull;
    if (provider == null) throw _noProviders();
    return aiEngine(provider);
  }
  if (lower.startsWith('ai:')) {
    return aiEngine(_findProvider(trimmed.substring(3), providers));
  }
  if (lower.startsWith('mozhi:')) {
    return _mozhiEngine(lower.substring('mozhi:'.length));
  }
  final provider = _matchProvider(trimmed, providers);
  if (provider != null) return aiEngine(provider);
  return _mozhiEngine(lower);
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
  final known = LanguageCatalog.byCode(trimmed) ?? LanguageCatalog.byName(trimmed);
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
