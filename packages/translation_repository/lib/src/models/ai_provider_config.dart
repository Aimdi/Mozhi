import 'package:llm_api/llm_api.dart';
import 'package:meta/meta.dart';

/// A user-configured AI backend.
///
/// [apiKey] is NOT part of [toJson]/[fromJson]: the app keeps keys in secure
/// storage and injects them with [copyWith].
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
  });

  factory fromJson() {
    throw UnimplementedError('TODO(translation_repository)');
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

  /// Heuristic: runs on the user's machine / LAN (privacy badge).
  bool get isLocal {
    throw UnimplementedError('TODO(translation_repository)');
  }

  LlmEndpoint toEndpoint() {
    throw UnimplementedError('TODO(translation_repository)');
  }

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
  }) {
    throw UnimplementedError('TODO(translation_repository)');
  }

  Map<String, dynamic> toJson() {
    throw UnimplementedError('TODO(translation_repository)');
  }

  @override
  bool operator ==(Object other) =>
      other is AiProviderConfig &&
      other.id == id &&
      other.name == name &&
      other.provider == provider &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.apiKey == apiKey &&
      other.effort == effort &&
      other.temperature == temperature &&
      other.enabled == enabled &&
      other.supportsVision == supportsVision;

  @override
  int get hashCode => Object.hash(
    id, name, provider, baseUrl, model, apiKey, effort, temperature, enabled,
    supportsVision,
  );
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
  });

  final String id;
  final String name;
  final LlmProvider provider;
  final String baseUrl;
  final String defaultModel;
  final List<String> suggestedModels;
  final bool requiresApiKey;
  final bool isLocal;

  /// Where users get a key.
  final String? apiKeyUrl;
  final String description;
  final String? defaultEffort;
  final Map<String, String> headers;

  /// Built-in presets. Must include at least: OpenAI, Anthropic (default
  /// model `claude-opus-5-5`, suggested `claude-sonnet-5-5`,
  /// `claude-haiku-5-5`; defaultEffort `low` for translation latency),
  /// Google Gemini (`gemini-flash-latest`), OpenRouter, Groq, DeepSeek,
  /// Mistral, xAI, Together, Ollama (local, native API,
  /// http://localhost:11434), LM Studio (local, http://localhost:1234/v1),
  /// llama.cpp server (local, http://localhost:8080/v1), and
  /// "Custom (OpenAI-compatible)".
  static List<AiProviderPreset> get all {
    throw UnimplementedError('TODO(translation_repository)');
  }

  static AiProviderPreset? byId(String id) {
    throw UnimplementedError('TODO(translation_repository)');
  }
}
