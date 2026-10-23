import 'dart:async';
import 'dart:math' as math;

import 'package:llama_engine/llama_engine.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/on_device_ai/data/on_device_runtime.dart';
import 'package:mozhi/platform/device_conditions.dart';

/// The in-process [LlmClient] of an on-device model
/// ([LlmProvider.onDevice]): the AI features talk to it as to any provider,
/// and nothing leaves the device.
///
/// Follows the [LlmClient] contract without the HTTP parts:
/// * [streamChat] maps the request to the engine
///   ([LlamaGenerateRequest]): system messages joined first (blank lines
///   between them), the other messages in order (Qwen3's last user
///   message ends with [noThinkSwitch], so it answers without reasoning
///   first), the request's sampling where set and else the catalogue
///   entry's (else the engine's), [LlmRequest.jsonOutput] as a JSON
///   grammar and [LlmRequest.stop]. The reply gets [LlmRequest.maxTokens]
///   tokens (when positive), else [replyTokensFor] the prompt (a bound on
///   its length, so that a model caught in a loop, or told to repeat
///   itself forever, does not keep the phone busy until the context is
///   full), and never more than the prompt leaves of the context; a
///   prompt that leaves less than an eighth of it fails at once with an
///   [LlmApiException]
///   ([contextMessage]), as does one the engine finds too long. Pieces
///   stream through [ThinkTagFilter]; a reply the engine ended at its
///   token limit ([LlamaFinishReason.length]: the cap, or a full context)
///   ends with an [LlmTruncatedException] carrying the text. Images are not
///   supported ([imagesMessage]). The model loads first when needed
///   ([OnDeviceRuntime.run]: requests run one at a time). Cancelling the
///   subscription cancels the generation (or the request, while it
///   waits).
/// * There is no timeout: nothing waits on a network, and the user can
///   cancel.
/// * [listModels] lists the installed models of the catalogue; [warmUp]
///   loads the model, unless the phone is hot or battery saver is on
///   ([DeviceConditions]: loading a model of 1-3 GB is heavy work the user
///   did not ask for yet); [close] does nothing (the runtime is shared).
class OnDeviceLlmClient implements LlmClient {
  new(
    this.endpoint, {
    required this.runtime,
    DeviceConditions? deviceConditions,
  }) : _deviceConditions = deviceConditions ?? DeviceConditions.instance;

  @override
  final LlmEndpoint endpoint;

  /// The engine and its queue (shared by every on-device client).
  final OnDeviceRuntime runtime;

  /// The phone's heat and battery saver ([warmUp]).
  final DeviceConditions _deviceConditions;

  /// What [streamChat] fails with for a prompt the model's context cannot
  /// hold with a reply.
  static const contextMessage =
      'The text is too long for the on-device model. Try a shorter text.';

  /// What [streamChat] fails with for a request with images.
  static const imagesMessage = 'On-device models cannot read images.';

  /// The smallest share of the context a reply must have (an eighth).
  static const _minReplyShare = 8;

  /// See [replyTokensFor].
  static const replyTokensPerPromptToken = 3;

  /// See [replyTokensFor].
  static const replyTokenMargin = 512;

  /// The most tokens the reply to a prompt of [promptTokens] tokens and
  /// [promptLength] characters gets when the request sets no
  /// [LlmRequest.maxTokens]: [replyTokensPerPromptToken] times its tokens,
  /// or its characters when they are more (text in scripts without spaces
  /// takes up to a token per character, and the reply may be in such a
  /// script while the prompt is not), plus [replyTokenMargin] (for short
  /// prompts and answers that explain). A translation, a proofread text
  /// or a few alternatives fit; a reply that would go on until the
  /// context is full does not.
  static int replyTokensFor({
    required int promptTokens,
    required int promptLength,
  }) =>
      math.max(promptTokens * replyTokensPerPromptToken, promptLength) +
      replyTokenMargin;

  @override
  Duration get timeout => LlmClient.defaultTimeout;

  /// [model] (a request's), else the endpoint's (`device://<model id>`).
  String _modelOf(String model) =>
      model.trim().isNotEmpty ? model.trim() : endpoint.baseUrl.host;

  @override
  Stream<String> streamChat(LlmRequest request) {
    late final StreamController<String> controller;
    var cancelled = false;
    // Cancelled with the returned stream's subscription (onCancel).
    // ignore: cancel_subscriptions
    StreamSubscription<String>? generation;
    final done = Completer<void>();

    void finish([Object? error, StackTrace? stackTrace]) {
      if (!done.isCompleted) done.complete();
      if (controller.isClosed) return;
      if (error != null) controller.addError(error, stackTrace);
      unawaited(controller.close());
    }

    Future<void> generate(LoadedOnDeviceModel loaded) async {
      if (cancelled) return;
      final messages = _messages(request, loaded.model);
      final engine = loaded.engine;
      final promptTokens = await engine.countTokens(messages);
      final room = loaded.contextSize - promptTokens;
      if (room < loaded.contextSize ~/ _minReplyShare) {
        throw const LlmApiException(contextMessage);
      }
      if (cancelled) return;
      // A cap of 0 or less would let the engine go on until the context is
      // full: none set.
      final asked = request.maxTokens;
      final cap = asked != null && asked > 0
          ? asked
          : replyTokensFor(
              promptTokens: promptTokens,
              promptLength: messages.fold(
                0,
                (length, message) => length + message.content.length,
              ),
            );
      final text = StringBuffer();
      var finishReason = LlamaFinishReason.stop;
      generation = engine
          .generate(
            LlamaGenerateRequest(
              messages: messages,
              sampling: _sampling(request, loaded.model.sampling),
              // The prompt and the reply must fit the context.
              maxTokens: math.min(cap, room),
              jsonOutput: request.jsonOutput,
              stop: request.stop,
              onFinish: (stats) => finishReason = stats.finishReason,
            ),
          )
          .transform(const ThinkTagFilter())
          .listen(
            (delta) {
              text.write(delta);
              controller.add(delta);
            },
            onError: (Object error, StackTrace stackTrace) =>
                finish(_mapError(error), stackTrace),
            onDone: () => finish(
              finishReason == LlamaFinishReason.length
                  ? LlmTruncatedException(
                      partialText: text.toString(),
                      reason: 'length',
                    )
                  : null,
            ),
            cancelOnError: true,
          );
      await done.future;
    }

    controller = StreamController<String>(
      onListen: () {
        if (request.messages.any((message) => message.images.isNotEmpty)) {
          finish(const LlmApiException(imagesMessage));
          return;
        }
        unawaited(
          runtime
              .run(
                _modelOf(request.model),
                generate,
                isCancelled: () => cancelled,
              )
              .then(
                (_) => finish(),
                onError: (Object error, StackTrace stackTrace) =>
                    finish(_mapError(error), stackTrace),
              ),
        );
      },
      onPause: () => generation?.pause(),
      onResume: () => generation?.resume(),
      onCancel: () async {
        cancelled = true;
        final running = generation;
        if (!done.isCompleted) done.complete();
        // Cancelling the subscription cancels the generation.
        await running?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<String> chat(LlmRequest request) async {
    final buffer = StringBuffer();
    await streamChat(request).forEach(buffer.write);
    return buffer.toString();
  }

  /// The installed models of the catalogue, sorted by id.
  @override
  Future<List<LlmModel>> listModels() async {
    final models = await runtime.installed();
    return [
      for (final model in models)
        LlmModel(
          id: model.id,
          displayName: model.displayName,
          contextWindow: model.contextSize,
        ),
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  /// Loads [model] (sends nothing anywhere); false when it is not
  /// installed or cannot be loaded, and, without loading it, while the
  /// phone is hot or battery saver is on ([DeviceConditions]; the first
  /// request loads it then).
  @override
  Future<bool> warmUp(String model) async {
    try {
      final conditions = await _deviceConditions.refresh();
      if (conditions.strain != null) return false;
      await runtime.run(_modelOf(model), (_) async {}, generating: false);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  void close() {}

  /// The chat of [request] for the model's template: every system message
  /// first, joined by blank lines, then the others in order. Qwen3's last
  /// user message ends with `/no_think`: it reasons before it answers
  /// unless told not to (its soft switch), and a phone has no time for
  /// that (the empty reasoning block it still writes is filtered out).
  static List<LlamaChatMessage> _messages(
    LlmRequest request,
    LlamaCatalogModel model,
  ) {
    final system = [
      for (final message in request.messages)
        if (message.role == LlmRole.system && message.content.isNotEmpty)
          message.content,
    ];
    final others = [
      for (final message in request.messages)
        if (message.role != LlmRole.system) message,
    ];
    final last = others.lastIndexWhere((m) => m.role == LlmRole.user);
    final noThink = model.family == qwen3Family;
    return [
      if (system.isNotEmpty)
        LlamaChatMessage(LlamaRole.system, system.join('\n\n')),
      for (final (index, message) in others.indexed)
        if (message.role == LlmRole.assistant)
          LlamaChatMessage(LlamaRole.assistant, message.content)
        else
          LlamaChatMessage(
            LlamaRole.user,
            noThink && index == last
                ? '${message.content} $noThinkSwitch'
                : message.content,
          ),
    ];
  }

  /// The catalogue family of Qwen3 models.
  static const qwen3Family = 'qwen3';

  /// What Qwen3's last user message ends with (see [streamChat]).
  static const noThinkSwitch = '/no_think';

  /// The request's sampling where it sets it, else [catalog]'s, else the
  /// engine's defaults.
  static LlamaSampling _sampling(
    LlmRequest request,
    LlamaCatalogSampling catalog,
  ) {
    const defaults = LlamaSampling();
    return LlamaSampling(
      temperature:
          request.temperature ?? catalog.temperature ?? defaults.temperature,
      topK: request.topK ?? catalog.topK ?? defaults.topK,
      topP: request.topP ?? catalog.topP ?? defaults.topP,
      minP: catalog.minP ?? defaults.minP,
      repeatPenalty:
          request.repeatPenalty ??
          catalog.repeatPenalty ??
          defaults.repeatPenalty,
    );
  }

  /// [error] of the engine as an [LlmApiException].
  static Object _mapError(Object error) => switch (error) {
    LlmApiException() => error,
    LlamaContextException() => LlmApiException(contextMessage, body: '$error'),
    LlamaCancelledException() => const LlmApiException(
      'The on-device model was stopped.',
    ),
    _ => LlmApiException(
      'The on-device model stopped with an error.',
      body: '$error',
    ),
  };
}
