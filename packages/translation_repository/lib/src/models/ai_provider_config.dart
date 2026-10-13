import 'package:collection/collection.dart';
import 'package:llm_api/llm_api.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/src/models/prompt_profile.dart';

/// The kind of service an [AiProviderConfig] talks to.
enum MtService {
  /// A large language model reached through [AiProviderConfig.provider]
  /// (the default).
  llm,

  /// The DeepL API v2 (Free or Pro). [AiProviderConfig.apiKey] is the DeepL
  /// auth key; an empty [AiProviderConfig.baseUrl] picks the official API
  /// from the key (`:fx` keys use the free API), otherwise it is a proxy.
  deepl,

  /// A LibreTranslate server at [AiProviderConfig.baseUrl];
  /// [AiProviderConfig.apiKey] is only needed by servers that require one.
  libreTranslate;

  /// Parses [value] (an enum name; case, `_`, `-` and spaces are ignored,
  /// and `libre` means [libreTranslate]); null when unknown.
  static MtService? tryParse(Object? value) {
    if (value is! String) return null;
    final key = value.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    for (final service in MtService.values) {
      if (service.name.toLowerCase() == key) return service;
    }
    return key == 'libre' ? MtService.libreTranslate : null;
  }
}

/// A user-configured translation backend: an AI (LLM) provider or, with a
/// non-default [service], a classic machine translation service (DeepL or
/// LibreTranslate) that is used with its own key or server.
///
/// [apiKey] is NOT part of [toJson]/[AiProviderConfig.fromJson]: the app
/// keeps keys in secure storage and injects them with [copyWith].
@immutable
class AiProviderConfig {
  const new({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.presetId,
    this.effort,
    this.temperature,
    this.headers = const {},
    this.enabled = true,
    this.supportsVision = false,
    this.service = MtService.llm,
    this.promptProfile = PromptProfile.auto,
  });

  /// Tolerant counterpart of [toJson]. Throws [FormatException] only when
  /// `id` is missing; every other field falls back to a sensible default.
  /// An `apiKey` entry, if present, is ignored.
  factory fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('AiProviderConfig.fromJson: missing "id"');
    }
    final temperature = json['temperature'];
    final headers = json['headers'];
    return AiProviderConfig(
      id: id,
      name: _string(json['name']) ?? id,
      provider: _parseProvider(json['provider']),
      baseUrl: _string(json['baseUrl']) ?? '',
      model: _string(json['model']) ?? '',
      presetId: _string(json['presetId']),
      effort: _string(json['effort']),
      temperature: temperature is num ? temperature.toDouble() : null,
      headers: headers is Map
          ? {
              for (final MapEntry(:key, :value) in headers.entries)
                if (key is String && value is String) key: value,
            }
          : const {},
      enabled: json['enabled'] != false,
      supportsVision: json['supportsVision'] == true,
      service: MtService.tryParse(json['service']) ?? MtService.llm,
      promptProfile:
          PromptProfile.tryParse(json['promptProfile']) ?? PromptProfile.auto,
    );
  }

  /// Stable unique id (e.g. a timestamp-based string).
  final String id;

  /// Display name, e.g. "Claude", "Local Qwen".
  final String name;
  final LlmProvider provider;
  final String baseUrl;
  final String model;
  final String? apiKey;

  /// The [AiProviderPreset.id] this was created from, if any.
  final String? presetId;

  /// See `LlmRequest.effort`.
  final String? effort;
  final double? temperature;
  final Map<String, String> headers;
  final bool enabled;

  /// Whether the model accepts images (enables image translation via AI).
  final bool supportsVision;

  /// [MtService.llm] (default) for AI providers; [MtService.deepl] or
  /// [MtService.libreTranslate] for machine translation services, whose
  /// [provider], [model], [effort], [temperature], [headers],
  /// [supportsVision] and [promptProfile] are ignored.
  final MtService service;

  /// How prompts are built for [model]; [PromptProfile.auto] (default)
  /// detects translation-specialised models from the model id. See
  /// [resolvedPromptProfile].
  final PromptProfile promptProfile;

  /// Whether this is a machine translation service rather than an LLM.
  bool get isMtService => service != MtService.llm;

  /// [promptProfile] resolved against [model] (never [PromptProfile.auto]).
  PromptProfile get resolvedPromptProfile => promptProfile.resolve(model);

  /// Heuristic: runs on the user's machine / LAN (privacy badge).
  ///
  /// True for `localhost`, loopback (127.0.0.0/8, ::1), private ranges
  /// (10/8, 172.16/12, 192.168/16, link-local, IPv6 ULA), the CGNAT range
  /// used by Tailscale (100.64/10), LAN suffixes (`.local`, `.lan`,
  /// `.home.arpa`, `.internal`, `.ts.net`, ...) and bare host names without
  /// dots (e.g. a Docker service name).
  bool get isLocal => isLocalHost(_hostOf(baseUrl));

  LlmEndpoint toEndpoint() {
    final key = apiKey?.trim();
    return LlmEndpoint(
      provider: provider,
      baseUrl: Uri.parse(_normalizeBaseUrl(baseUrl)),
      apiKey: key == null || key.isEmpty ? null : key,
      headers: headers,
    );
  }

  /// Nullable fields can be reset with the `clear*` flags (a `null` argument
  /// keeps the current value).
  AiProviderConfig copyWith({
    String? name,
    LlmProvider? provider,
    String? baseUrl,
    String? model,
    String? apiKey,
    String? presetId,
    String? effort,
    double? temperature,
    Map<String, String>? headers,
    bool? enabled,
    bool? supportsVision,
    MtService? service,
    PromptProfile? promptProfile,
    bool clearApiKey = false,
    bool clearPresetId = false,
    bool clearEffort = false,
    bool clearTemperature = false,
  }) => AiProviderConfig(
    id: id,
    name: name ?? this.name,
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: clearApiKey ? null : apiKey ?? this.apiKey,
    presetId: clearPresetId ? null : presetId ?? this.presetId,
    effort: clearEffort ? null : effort ?? this.effort,
    temperature: clearTemperature ? null : temperature ?? this.temperature,
    headers: headers ?? this.headers,
    enabled: enabled ?? this.enabled,
    supportsVision: supportsVision ?? this.supportsVision,
    service: service ?? this.service,
    promptProfile: promptProfile ?? this.promptProfile,
  );

  /// Never contains the API key. `service` is only written for machine
  /// translation services and `promptProfile` only when it is not
  /// [PromptProfile.auto].
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'provider': provider.name,
    'baseUrl': baseUrl,
    'model': model,
    if (presetId != null) 'presetId': presetId,
    if (effort != null) 'effort': effort,
    if (temperature != null) 'temperature': temperature,
    if (headers.isNotEmpty) 'headers': Map<String, String>.of(headers),
    'enabled': enabled,
    'supportsVision': supportsVision,
    if (service != MtService.llm) 'service': service.name,
    if (promptProfile != PromptProfile.auto)
      'promptProfile': promptProfile.name,
  };

  @override
  bool operator ==(Object other) =>
      other is AiProviderConfig &&
      other.id == id &&
      other.name == name &&
      other.provider == provider &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.apiKey == apiKey &&
      other.presetId == presetId &&
      other.effort == effort &&
      other.temperature == temperature &&
      other.enabled == enabled &&
      other.supportsVision == supportsVision &&
      other.service == service &&
      other.promptProfile == promptProfile &&
      const MapEquality<String, String>().equals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    provider,
    baseUrl,
    model,
    apiKey,
    presetId,
    effort,
    temperature,
    enabled,
    supportsVision,
    service,
    promptProfile,
    const MapEquality<String, String>().hash(headers),
  );

  @override
  String toString() => service == MtService.llm
      ? 'AiProviderConfig($id, $name, ${provider.name}, $baseUrl, $model)'
      : 'AiProviderConfig($id, $name, ${service.name}, $baseUrl)';

  /// Whether [host] (a bare host name or IP literal, as in [Uri.host]) is on
  /// this machine or a private network. See [isLocal].
  static bool isLocalHost(String host) {
    var h = host.trim().toLowerCase();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h.isEmpty) return false;
    if (h == 'localhost' || h.endsWith('.localhost')) return true;

    final ipv4 = _parseIpv4(h);
    if (ipv4 != null) return _isPrivateIpv4(ipv4);
    if (h.contains(':')) return _isPrivateIpv6(h);

    const lanSuffixes = [
      '.local',
      '.lan',
      '.home.arpa',
      '.internal',
      '.intranet',
      '.localdomain',
      '.home',
      '.corp',
      '.private',
      '.ts.net',
    ];
    if (lanSuffixes.any(h.endsWith)) return true;
    // Bare host names (no dots) only resolve on the local network.
    return !h.contains('.');
  }
}

String? _string(Object? value) => value is String ? value : null;

LlmProvider _parseProvider(Object? value) {
  if (value is! String) return LlmProvider.openAiCompatible;
  final key = value.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  for (final p in LlmProvider.values) {
    if (p.name.toLowerCase() == key) return p;
  }
  return switch (key) {
    'claude' => LlmProvider.anthropic,
    'google' || 'googleai' || 'googlegemini' => LlmProvider.gemini,
    _ => LlmProvider.openAiCompatible,
  };
}

/// Trims whitespace and trailing slashes, and adds `http://` (for local
/// hosts) or `https://` when the scheme is missing.
String _normalizeBaseUrl(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  if (u.isEmpty || u.contains('://')) return u;
  final host = _hostOf(u);
  return '${AiProviderConfig.isLocalHost(host) ? 'http' : 'https'}://$u';
}

String _hostOf(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';
  final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  return Uri.tryParse(withScheme)?.host ?? '';
}

List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255 || part.isEmpty) return null;
    octets.add(n);
  }
  return octets;
}

bool _isPrivateIpv4(List<int> ip) {
  final [a, b, ...] = ip;
  return a == 127 || // loopback
      a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254) || // link-local
      (a == 100 && b >= 64 && b <= 127) || // CGNAT / Tailscale
      (a == 0 && b == 0 && ip[2] == 0 && ip[3] == 0);
}

bool _isPrivateIpv6(String host) {
  final h = host.split('%').first; // zone id
  if (h == '::1' || h == '0:0:0:0:0:0:0:1' || h == '::') return true;
  // IPv4-mapped (::ffff:192.168.1.2).
  final mapped = RegExp(r'^::ffff:(\d+\.\d+\.\d+\.\d+)$').firstMatch(h);
  if (mapped != null) {
    final v4 = _parseIpv4(mapped.group(1)!);
    return v4 != null && _isPrivateIpv4(v4);
  }
  final first = h.split(':').first;
  if (first.isEmpty) return false;
  final value = int.tryParse(first, radix: 16);
  if (value == null) return false;
  // fc00::/7 unique local (incl. Tailscale's fd7a:115c:a1e0::/48) and
  // fe80::/10 link-local.
  return (value & 0xfe00) == 0xfc00 || (value & 0xffc0) == 0xfe80;
}

/// A ready-made provider template shown in "Add AI provider".
@immutable
class AiProviderPreset {
  const new({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    required this.defaultModel,
    this.suggestedModels = const [],
    this.requiresApiKey = true,
    this.isLocal = false,
    this.apiKeyUrl,
    this.description = '',
    this.defaultEffort,
    this.headers = const {},
    this.service = MtService.llm,
  });

  final String id;
  final String name;
  final LlmProvider provider;
  final String baseUrl;

  /// Empty when the model must be picked from the server's model list
  /// (local servers, custom endpoints).
  final String defaultModel;
  final List<String> suggestedModels;
  final bool requiresApiKey;
  final bool isLocal;

  /// Where users get a key.
  final String? apiKeyUrl;
  final String description;
  final String? defaultEffort;
  final Map<String, String> headers;

  /// [MtService.llm] for AI presets ([all]); a machine translation service
  /// for [mtServices].
  final MtService service;

  /// Builds a config from this preset.
  AiProviderConfig toConfig({
    required String id,
    String? name,
    String? model,
    String? apiKey,
    String? baseUrl,
  }) => AiProviderConfig(
    id: id,
    name: name ?? this.name,
    provider: provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? defaultModel,
    apiKey: apiKey,
    presetId: this.id,
    effort: defaultEffort,
    headers: headers,
    service: service,
  );

  /// Built-in presets. Must include at least: OpenAI, Anthropic (default
  /// model `claude-opus-5-5`, suggested `claude-sonnet-5-5`,
  /// `claude-haiku-5-5`; defaultEffort `low` for translation latency),
  /// Google Gemini (`gemini-flash-latest`), OpenRouter, Groq, DeepSeek,
  /// Mistral, xAI, Together, Ollama (local, native API,
  /// http://localhost:11434), LM Studio (local, http://localhost:1234/v1),
  /// llama.cpp server (local, http://localhost:8080/v1), and
  /// "Custom (OpenAI-compatible)".
  static List<AiProviderPreset> get all => _presets;

  /// Machine translation services that are used with the user's own key or
  /// server: DeepL API (`deepl`) and LibreTranslate (`libretranslate`).
  /// Kept out of [all], which lists LLM providers only.
  static List<AiProviderPreset> get mtServices => _mtPresets;

  /// Looks [id] up in [all] and [mtServices].
  static AiProviderPreset? byId(String id) {
    for (final preset in [..._presets, ..._mtPresets]) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  static const _mtPresets = <AiProviderPreset>[
    AiProviderPreset(
      id: 'deepl',
      name: 'DeepL API',
      provider: LlmProvider.openAiCompatible,
      baseUrl: '',
      defaultModel: '',
      apiKeyUrl: 'https://www.deepl.com/your-account/keys',
      description:
          'DeepL with your own API key (Free or Pro). Leave the URL empty '
          'to use the official API.',
      service: MtService.deepl,
    ),
    AiProviderPreset(
      id: 'libretranslate',
      name: 'LibreTranslate',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://libretranslate.com',
      defaultModel: '',
      requiresApiKey: false,
      apiKeyUrl: 'https://portal.libretranslate.com',
      description:
          'Open-source machine translation on your own server or '
          'libretranslate.com (needs a key there).',
      service: MtService.libreTranslate,
    ),
  ];

  static const _presets = <AiProviderPreset>[
    AiProviderPreset(
      id: 'openai',
      name: 'OpenAI',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://api.openai.com/v1',
      defaultModel: 'gpt-5-mini',
      suggestedModels: ['gpt-5-mini', 'gpt-5', 'gpt-5-nano'],
      apiKeyUrl: 'https://platform.openai.com/api-keys',
      description: 'GPT models from OpenAI.',
      defaultEffort: 'low',
    ),
    AiProviderPreset(
      id: 'anthropic',
      name: 'Anthropic',
      provider: LlmProvider.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      defaultModel: 'claude-opus-5-5',
      suggestedModels: [
        'claude-opus-5-5',
        'claude-sonnet-5-5',
        'claude-haiku-5-5',
      ],
      apiKeyUrl: 'https://console.anthropic.com/settings/keys',
      description: 'Claude models from Anthropic.',
      defaultEffort: 'low',
    ),
    AiProviderPreset(
      id: 'gemini',
      name: 'Google Gemini',
      provider: LlmProvider.gemini,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      defaultModel: 'gemini-flash-latest',
      suggestedModels: [
        'gemini-flash-latest',
        'gemini-pro-latest',
        'gemini-flash-lite-latest',
      ],
      apiKeyUrl: 'https://aistudio.google.com/apikey',
      description: 'Gemini models via Google AI Studio (free tier available).',
    ),
    AiProviderPreset(
      id: 'openrouter',
      name: 'OpenRouter',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://openrouter.ai/api/v1',
      defaultModel: 'openrouter/auto',
      suggestedModels: ['openrouter/auto', 'openai/gpt-5-mini'],
      apiKeyUrl: 'https://openrouter.ai/keys',
      description: 'One key for hundreds of models from many providers.',
      headers: {
        'HTTP-Referer': 'https://github.com/Aimdi/Mozhi',
        'X-Title': 'Mozhi',
      },
    ),
    AiProviderPreset(
      id: 'groq',
      name: 'Groq',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://api.groq.com/openai/v1',
      defaultModel: 'openai/gpt-oss-120b',
      suggestedModels: [
        'openai/gpt-oss-120b',
        'openai/gpt-oss-20b',
        'llama-3.3-70b-versatile',
      ],
      apiKeyUrl: 'https://console.groq.com/keys',
      description: 'Very fast inference of open models.',
    ),
    AiProviderPreset(
      id: 'deepseek',
      name: 'DeepSeek',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://api.deepseek.com/v1',
      defaultModel: 'deepseek-chat',
      suggestedModels: ['deepseek-chat', 'deepseek-reasoner'],
      apiKeyUrl: 'https://platform.deepseek.com/api_keys',
      description: 'Inexpensive models from DeepSeek, strong in Chinese.',
    ),
    AiProviderPreset(
      id: 'mistral',
      name: 'Mistral AI',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://api.mistral.ai/v1',
      defaultModel: 'mistral-large-latest',
      suggestedModels: [
        'mistral-large-latest',
        'mistral-medium-latest',
        'mistral-small-latest',
      ],
      apiKeyUrl: 'https://console.mistral.ai/api-keys',
      description: 'European models from Mistral AI.',
    ),
    AiProviderPreset(
      id: 'xai',
      name: 'xAI',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://api.x.ai/v1',
      defaultModel: 'grok-4',
      suggestedModels: ['grok-4'],
      apiKeyUrl: 'https://console.x.ai',
      description: 'Grok models from xAI.',
    ),
    AiProviderPreset(
      id: 'together',
      name: 'Together AI',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'https://api.together.xyz/v1',
      defaultModel: 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
      suggestedModels: [
        'meta-llama/Llama-3.3-70B-Instruct-Turbo',
        'deepseek-ai/DeepSeek-V3',
      ],
      apiKeyUrl: 'https://api.together.ai/settings/api-keys',
      description: 'Hosted open models (Llama, Qwen, DeepSeek, ...).',
    ),
    AiProviderPreset(
      id: 'ollama',
      name: 'Ollama',
      provider: LlmProvider.ollama,
      baseUrl: 'http://localhost:11434',
      defaultModel: 'gemma3',
      suggestedModels: ['gemma3', 'qwen3', 'aya-expanse', 'llama3.1'],
      requiresApiKey: false,
      isLocal: true,
      description: 'Run open models on your own computer or server.',
    ),
    AiProviderPreset(
      id: 'lmstudio',
      name: 'LM Studio',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'http://localhost:1234/v1',
      defaultModel: '',
      requiresApiKey: false,
      isLocal: true,
      description: 'Local models served by the LM Studio desktop app.',
    ),
    AiProviderPreset(
      id: 'llamacpp',
      name: 'llama.cpp server',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'http://localhost:8080/v1',
      defaultModel: '',
      requiresApiKey: false,
      isLocal: true,
      description: 'A local llama-server (llama.cpp) instance.',
    ),
    AiProviderPreset(
      id: 'custom',
      name: 'Custom (OpenAI-compatible)',
      provider: LlmProvider.openAiCompatible,
      baseUrl: '',
      defaultModel: '',
      requiresApiKey: false,
      description:
          'Any OpenAI-compatible endpoint: vLLM, LocalAI, Jan, LiteLLM, ...',
    ),
  ];
}
