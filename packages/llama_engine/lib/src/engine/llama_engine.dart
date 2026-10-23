import 'package:meta/meta.dart';

/// The native engine failed: it could not be loaded, a model could not be
/// opened, or a generation failed. The message comes from the engine.
class LlamaEngineException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'LlamaEngineException($message)';
}

/// A generation or a token count needs a model, and none is loaded
/// ([LlamaEngine.load]).
final class LlamaNotLoadedException extends LlamaEngineException {
  const new() : super('no model is loaded');

  @override
  String toString() => 'LlamaNotLoadedException()';
}

/// The prompt does not fit into the context together with the requested
/// answer (`maxTokens`): shorten the input or load a larger context.
final class LlamaContextException extends LlamaEngineException {
  const new(super.message, {this.promptTokens, this.contextSize});

  /// Tokens of the formatted prompt, when known.
  final int? promptTokens;

  /// The loaded context size in tokens, when known.
  final int? contextSize;

  @override
  String toString() =>
      'LlamaContextException($promptTokens tokens, context $contextSize)';
}

/// A generation was stopped by [LlamaEngine.cancel] (or the engine was
/// disposed while it ran or waited).
final class LlamaCancelledException extends LlamaEngineException {
  const new() : super('cancelled');

  @override
  String toString() => 'LlamaCancelledException()';
}

/// Roles of a chat message for the model's chat template.
enum LlamaRole { system, user, assistant }

/// One message of a conversation.
@immutable
final class LlamaChatMessage {
  const new(this.role, this.content);

  final LlamaRole role;
  final String content;

  @override
  bool operator ==(Object other) =>
      other is LlamaChatMessage &&
      other.role == role &&
      other.content == content;

  @override
  int get hashCode => Object.hash(role, content);

  // Never the content: it is the user's text.
  @override
  String toString() =>
      'LlamaChatMessage(${role.name}, ${content.length} chars)';
}

/// How the next token is picked: a repetition penalty over the last
/// [repeatLastN] tokens (prompt included), then top-k, top-p and min-p
/// filtering and a random pick at [temperature]. The defaults are Hy-MT2's
/// recommended settings.
@immutable
final class LlamaSampling {
  const new({
    this.temperature = 0.7,
    this.topK = 20,
    this.topP = 0.6,
    this.minP = 0.0,
    this.repeatPenalty = 1.05,
    this.repeatLastN = 64,
    this.seed,
  });

  /// Deterministic: always the most likely token (greedy).
  static const greedy = LlamaSampling(temperature: 0);

  /// `<= 0` picks the most likely token (greedy).
  final double temperature;

  /// `<= 0` turns top-k off.
  final int topK;

  /// `>= 1` turns top-p (nucleus sampling) off.
  final double topP;

  /// `<= 0` turns min-p off.
  final double minP;

  /// `1` turns the repetition penalty off.
  final double repeatPenalty;

  /// Tokens the penalty looks back at; `0` turns it off, `-1` means the
  /// whole context.
  final int repeatLastN;

  /// A fixed seed makes sampling repeatable; null picks a random one.
  final int? seed;

  LlamaSampling copyWith({
    double? temperature,
    int? topK,
    double? topP,
    double? minP,
    double? repeatPenalty,
    int? repeatLastN,
    int? seed,
  }) => LlamaSampling(
    temperature: temperature ?? this.temperature,
    topK: topK ?? this.topK,
    topP: topP ?? this.topP,
    minP: minP ?? this.minP,
    repeatPenalty: repeatPenalty ?? this.repeatPenalty,
    repeatLastN: repeatLastN ?? this.repeatLastN,
    seed: seed ?? this.seed,
  );

  @override
  bool operator ==(Object other) =>
      other is LlamaSampling &&
      other.temperature == temperature &&
      other.topK == topK &&
      other.topP == topP &&
      other.minP == minP &&
      other.repeatPenalty == repeatPenalty &&
      other.repeatLastN == repeatLastN &&
      other.seed == seed;

  @override
  int get hashCode => Object.hash(
    temperature,
    topK,
    topP,
    minP,
    repeatPenalty,
    repeatLastN,
    seed,
  );

  @override
  String toString() =>
      'LlamaSampling(temperature: $temperature, topK: $topK, topP: $topP, '
      'minP: $minP, repeatPenalty: $repeatPenalty, '
      'repeatLastN: $repeatLastN, seed: $seed)';
}

/// Why a generation ended.
enum LlamaFinishReason {
  /// The model ended its answer, or a stop string was reached.
  stop,

  /// `maxTokens` was reached or the context is full: the answer may be cut
  /// short.
  length,
}

/// About a finished generation ([LlamaGenerateRequest.onFinish]).
@immutable
final class LlamaGenerateStats {
  const new({
    required this.promptTokens,
    required this.generatedTokens,
    required this.finishReason,
    this.promptDuration = Duration.zero,
    this.generateDuration = Duration.zero,
  });

  final int promptTokens;
  final int generatedTokens;
  final LlamaFinishReason finishReason;

  /// Time spent processing the prompt (before the first token).
  final Duration promptDuration;

  /// Time spent generating the answer.
  final Duration generateDuration;

  /// Generated tokens per second, or 0 when unknown.
  double get tokensPerSecond => generateDuration == Duration.zero
      ? 0
      : generatedTokens *
            Duration.microsecondsPerSecond /
            generateDuration.inMicroseconds;

  @override
  bool operator ==(Object other) =>
      other is LlamaGenerateStats &&
      other.promptTokens == promptTokens &&
      other.generatedTokens == generatedTokens &&
      other.finishReason == finishReason &&
      other.promptDuration == promptDuration &&
      other.generateDuration == generateDuration;

  @override
  int get hashCode => Object.hash(
    promptTokens,
    generatedTokens,
    finishReason,
    promptDuration,
    generateDuration,
  );

  @override
  String toString() =>
      'LlamaGenerateStats($promptTokens + $generatedTokens tokens, '
      '${finishReason.name})';
}

/// What to generate: a conversation formatted with the model's chat
/// template, answered by the model.
@immutable
final class LlamaGenerateRequest {
  const new({
    required this.messages,
    this.sampling = const LlamaSampling(),
    this.maxTokens = 1024,
    this.jsonOutput = false,
    this.stop = const [],
    this.onFinish,
  });

  final List<LlamaChatMessage> messages;
  final LlamaSampling sampling;

  /// Tokens to generate at most; `<= 0` until the context is full. The
  /// prompt must leave room for them (else [LlamaContextException]).
  final int maxTokens;

  /// The answer is one JSON object (a grammar constrains the output).
  final bool jsonOutput;

  /// The answer ends before the first of these strings (not included).
  final List<String> stop;

  /// Called on the caller's isolate when the generation ended normally
  /// (not when it failed or was cancelled), before the stream closes: e.g.
  /// to tell an answer cut short ([LlamaFinishReason.length]) from a
  /// complete one.
  final void Function(LlamaGenerateStats stats)? onFinish;
}

/// About a loaded model.
@immutable
final class LlamaModelInfo {
  const new({
    required this.architecture,
    required this.name,
    required this.contextLength,
    required this.parameters,
    required this.sizeBytes,
    required this.chatTemplate,
    this.chatTemplateName,
    this.contextSize = 0,
    this.description = '',
    this.engine = '',
  });

  /// Parses `mozhi_llama_model_info()`'s JSON (with the engine's version
  /// and CPU features as [engine]).
  factory fromNative(Map<String, Object?> json, {String engine = ''}) {
    String text(String key) => json[key] is String ? json[key]! as String : '';
    int number(String key) => switch (json[key]) {
      final int value => value,
      final num value => value.toInt(),
      _ => 0,
    };
    final templateName = json['chat_template_name'];
    return LlamaModelInfo(
      architecture: text('architecture'),
      name: text('name'),
      contextLength: number('n_ctx_train'),
      parameters: number('n_params'),
      sizeBytes: number('size'),
      chatTemplate: json['chat_template'] == true,
      chatTemplateName: templateName is String ? templateName : null,
      contextSize: number('n_ctx'),
      description: text('description'),
      engine: engine,
    );
  }

  /// GGUF `general.architecture`, e.g. `hunyuan-dense`, `gemma4`, `qwen3`.
  final String architecture;

  /// GGUF `general.name` (may be empty).
  final String name;

  /// The context length the model was trained with, in tokens.
  final int contextLength;

  /// Number of parameters (weights).
  final int parameters;

  /// Bytes of the weights.
  final int sizeBytes;

  /// Whether the model's chat template is supported: [LlamaEngine.generate]
  /// and [LlamaEngine.countTokens] need it.
  final bool chatTemplate;

  /// The chat format the engine uses (`chatml`, `gemma4`, `hunyuan-dense`,
  /// `qwen3`, ...), when it has a name.
  final String? chatTemplateName;

  /// The loaded context size in tokens (at most [contextLength]).
  final int contextSize;

  /// llama.cpp's description, e.g. `qwen3 1.7B Q4_K - Medium`.
  final String description;

  /// The engine and the CPU variant it runs on, for diagnostics, e.g.
  /// `llama.cpp 0.6.0 (ggml 0.26.0, CPU armv8.2-a+dotprod+fp16)`.
  final String engine;

  @override
  bool operator ==(Object other) =>
      other is LlamaModelInfo &&
      other.architecture == architecture &&
      other.name == name &&
      other.contextLength == contextLength &&
      other.parameters == parameters &&
      other.sizeBytes == sizeBytes &&
      other.chatTemplate == chatTemplate &&
      other.chatTemplateName == chatTemplateName &&
      other.contextSize == contextSize &&
      other.description == description &&
      other.engine == engine;

  @override
  int get hashCode => Object.hash(
    architecture,
    name,
    contextLength,
    parameters,
    sizeBytes,
    chatTemplate,
    chatTemplateName,
    contextSize,
    description,
    engine,
  );

  @override
  String toString() =>
      'LlamaModelInfo($architecture, $name, $parameters parameters, '
      'context $contextSize/$contextLength, template $chatTemplateName)';
}

/// Runs llama.cpp (`libmozhi_llama`) with one loaded model, off the UI
/// isolate.
abstract interface class LlamaEngine {
  /// Loads [modelPath] (mmap) unless it is loaded already; unloads any
  /// other model first. [contextSize] caps n_ctx (default 4096; at most the
  /// model's training context). [threads] <= 0 uses the engine's default
  /// (at most 4).
  ///
  /// Throws [LlamaEngineException] when the file cannot be loaded.
  Future<LlamaModelInfo> load(
    String modelPath, {
    int contextSize = 4096,
    int threads = 0,
  });

  /// Generates with the loaded model: UTF-8-complete text pieces as they
  /// come. Cancelling the subscription cancels the generation. Errors:
  /// [LlamaNotLoadedException], [LlamaContextException] (prompt too long),
  /// [LlamaEngineException]; [cancel] → [LlamaCancelledException]. One
  /// generation runs at a time: a second one waits.
  Stream<String> generate(LlamaGenerateRequest request);

  /// Counts the tokens of [messages] formatted with the chat template (as
  /// [generate] would send them).
  Future<int> countTokens(List<LlamaChatMessage> messages);

  /// Stops every generation that is running or waiting.
  Future<void> cancel();

  /// Frees the model and context (memory back to the system).
  Future<void> unload();

  /// The loaded model, if any.
  String? get loadedModelPath;

  /// Unloads the model and stops the background isolate. The engine stays
  /// usable; the next call starts it again.
  Future<void> dispose();
}
