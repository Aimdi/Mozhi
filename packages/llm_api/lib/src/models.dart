import 'package:meta/meta.dart';

/// Wire protocol spoken by an endpoint.
enum LlmProvider {
  /// `POST {base}/chat/completions` (SSE), `GET {base}/models`.
  /// Covers OpenAI, OpenRouter, Groq, DeepSeek, Mistral, Together, xAI,
  /// LM Studio, llama.cpp server, vLLM, LocalAI, Jan and Ollama's `/v1`.
  openAiCompatible,

  /// Anthropic Messages API: `POST {base}/messages` (SSE),
  /// `GET {base}/models`. Default base `https://api.anthropic.com/v1`.
  anthropic,

  /// Google Gemini: `POST {base}/models/{model}:streamGenerateContent?alt=sse`,
  /// `GET {base}/models`. Default base
  /// `https://generativelanguage.googleapis.com/v1beta`.
  gemini,

  /// Ollama native API: `POST {base}/api/chat` (NDJSON), `GET {base}/api/tags`.
  /// Default base `http://localhost:11434`.
  ollama,
}

/// Where and how to reach a model API.
@immutable
class LlmEndpoint {
  const new({
    required this.provider,
    required this.baseUrl,
    this.apiKey,
    this.headers = const {},
  });

  final LlmProvider provider;

  /// Base URL *including* any version segment, e.g.
  /// `https://api.openai.com/v1`, `https://openrouter.ai/api/v1`,
  /// `http://192.168.1.5:1234/v1`, `https://api.anthropic.com/v1`.
  /// For [LlmProvider.ollama] it is the server root (no `/api`).
  final Uri baseUrl;

  /// Optional for local servers. Never logged.
  final String? apiKey;

  /// Extra headers sent with every request (e.g. the authentication
  /// header of a gateway in front of the provider).
  final Map<String, String> headers;
}

enum LlmRole { system, user, assistant }

/// An image attached to a user message (vision models).
///
/// Wire formats: OpenAI-compatible content part
/// `{"type": "image_url", "image_url": {"url": "data:<mime>;base64,<b64>"}}`;
/// Anthropic block `{"type": "image", "source": <source>}` with source
/// `{"type": "base64", "media_type": <mime>, "data": <b64>}`, placed before
/// the text block;
/// Gemini part `{"inlineData": {"mimeType": <mime>, "data": <b64>}}`;
/// Ollama message field `"images": [<b64>]`.
@immutable
class LlmImage {
  const new({required this.bytes, this.mimeType = 'image/png'});

  final List<int> bytes;
  final String mimeType;
}

@immutable
class LlmMessage {
  const new(this.role, this.content, {this.images = const []});
  const new system(this.content) : role = LlmRole.system, images = const [];
  const new user(this.content, {this.images = const []}) : role = LlmRole.user;
  const new assistant(this.content)
    : role = LlmRole.assistant,
      images = const [];

  final LlmRole role;
  final String content;

  /// Only meaningful on user messages. When empty, messages are sent in the
  /// provider's plain-string form.
  final List<LlmImage> images;

  @override
  bool operator ==(Object other) =>
      other is LlmMessage && other.role == role && other.content == content;

  @override
  int get hashCode => Object.hash(role, content);
}

/// One chat completion request.
@immutable
class LlmRequest {
  const new({
    required this.model,
    required this.messages,
    this.temperature,
    this.maxTokens,
    this.jsonOutput = false,
    this.effort,
    this.contextWindow,
  });

  final String model;

  /// May contain any number of system messages; providers that take a
  /// separate system field (Anthropic `system`, Gemini `systemInstruction`)
  /// join all system messages with blank lines.
  final List<LlmMessage> messages;

  /// Only sent when non-null. NOTE: current Anthropic models reject
  /// non-default sampling params, so callers should leave it null there.
  final double? temperature;

  /// Output cap. When null each provider uses its own safe default
  /// (Anthropic requires one: 64000 for streaming, retried once with 8192 if
  /// the API answers 400 mentioning `max_tokens`).
  final int? maxTokens;

  /// Ask for a JSON object response where the provider supports it reliably:
  /// OpenAI-compatible `response_format: {"type": "json_object"}` (retried
  /// once without it on HTTP 400), Gemini
  /// `generationConfig.responseMimeType: "application/json"`, Ollama
  /// `format: "json"`. Anthropic: no-op (prompt must ask for JSON).
  final bool jsonOutput;

  /// Reasoning effort hint: `low` | `medium` | `high` (Anthropic also
  /// `xhigh` | `max`). Anthropic: `output_config: {"effort": ...}` (retried
  /// once without it when the API answers 400 mentioning `effort` or
  /// `output_config`, as models without effort support do).
  /// OpenAI-compatible: `reasoning_effort` (only when non-null).
  /// Ignored by Gemini and Ollama.
  final String? effort;

  /// Context window (prompt + reply, in tokens) the server should allocate.
  ///
  /// Only Ollama lets the client choose it: sent as `options.num_ctx`. When
  /// null (or not positive) Ollama gets 8192, raised to 16384 or 32768
  /// when a rough estimate of the prompt plus its reply would not fit (see
  /// `OllamaClient.contextWindowFor`), and never less than the size used
  /// before for the same server and model in this session (Ollama reloads
  /// the model when it changes; see `OllamaClient.contextSizeFor`).
  /// Ollama's own default of a few thousand tokens silently drops the start
  /// of longer prompts. Ignored by the other providers, whose context size
  /// is fixed by the server.
  final int? contextWindow;

  LlmRequest copyWith({
    String? model,
    List<LlmMessage>? messages,
    double? temperature,
    int? maxTokens,
    bool? jsonOutput,
    String? effort,
    int? contextWindow,
  }) => LlmRequest(
    model: model ?? this.model,
    messages: messages ?? this.messages,
    temperature: temperature ?? this.temperature,
    maxTokens: maxTokens ?? this.maxTokens,
    jsonOutput: jsonOutput ?? this.jsonOutput,
    effort: effort ?? this.effort,
    contextWindow: contextWindow ?? this.contextWindow,
  );
}

/// A model advertised by a provider's model-listing endpoint.
@immutable
class LlmModel {
  const new({required this.id, this.displayName, this.contextWindow});

  /// The id to send in [LlmRequest.model]. For Gemini the `models/` prefix
  /// is stripped (`models/gemini-flash-latest` -> `gemini-flash-latest`).
  final String id;
  final String? displayName;
  final int? contextWindow;

  String get label => displayName?.isNotEmpty ?? false ? displayName! : id;

  @override
  bool operator ==(Object other) => other is LlmModel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
