import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:llm_api/src/llm_exception.dart';
import 'package:llm_api/src/models.dart';
import 'package:llm_api/src/providers/error_parsing.dart';
import 'package:llm_api/src/providers/http_llm_client.dart';
import 'package:llm_api/src/providers/response_end.dart';
import 'package:llm_api/src/streaming/ndjson_decoder.dart';
import 'package:llm_api/src/think_filter.dart';

/// Client for the Ollama native API ([LlmProvider.ollama]).
///
/// Streams `POST {base}/api/chat` (NDJSON) and lists models with
/// `GET {base}/api/tags`. Only `message.content` is emitted (never
/// `message.thinking`), piped through [ThinkTagFilter].
///
/// The response is complete at `done: true`; `done_reason: "length"` raises
/// [LlmTruncatedException] and a body that ends without `done: true` raises
/// [LlmInterruptedException].
///
/// Every chat request sets `options.num_ctx` (see [contextWindowFor]):
/// Ollama's default context of a few thousand tokens silently drops the
/// start of longer prompts, instructions included. Ollama reloads a model
/// (which takes seconds) whenever `num_ctx` changes, so the size is sticky:
/// [contextSizes] remembers the largest one used for each server and model,
/// and later requests never ask for less within the session.
///
/// [keepAlive], when set, is sent as `keep_alive` with every request and
/// with [warmUp].
class OllamaClient extends HttpLlmClient {
  new(
    super.endpoint, {
    super.httpClient,
    super.timeout,
    super.retryPolicy,
    this.keepAlive,
    OllamaContextSizes? contextSizes,
  }) : contextSizes = contextSizes ?? OllamaContextSizes.shared;

  /// How long Ollama keeps the model loaded after a request (`keep_alive`,
  /// sent in whole seconds; negative keeps it loaded until the server
  /// stops). Null leaves it to the server (five minutes by default).
  final Duration? keepAlive;

  /// Where the context size of each server and model is remembered;
  /// [OllamaContextSizes.shared] unless one was given.
  final OllamaContextSizes contextSizes;

  /// The `options.num_ctx` sent when [LlmRequest.contextWindow] is not set
  /// and the prompt is not long.
  static const defaultContextWindow = 8192;

  /// The largest `options.num_ctx` chosen automatically for long prompts.
  static const maxAutoContextWindow = 32768;

  /// The `options.num_ctx` sent for [request].
  ///
  /// [LlmRequest.contextWindow] when it is positive. Otherwise
  /// [defaultContextWindow], doubled (up to [maxAutoContextWindow]) while a
  /// rough estimate of the prompt plus its reply does not fit. The estimate
  /// errs on the large side: 2 characters per token (so that non-Latin
  /// scripts fit too), 1024 tokens per image, a reply of
  /// [LlmRequest.maxTokens] or else as long as the text, and 1024 tokens of
  /// headroom. The size only grows in powers of two because Ollama reloads
  /// the model whenever `num_ctx` changes.
  ///
  /// This is what [request] needs; what is sent is [contextSizeFor].
  static int contextWindowFor(LlmRequest request) {
    if (request.contextWindow case final size? when size > 0) return size;
    var characters = 0;
    var images = 0;
    for (final message in request.messages) {
      characters += message.content.length;
      images += message.images.length;
    }
    final text = (characters / 2).ceil();
    final needed = text + images * 1024 + (request.maxTokens ?? text) + 1024;
    var size = defaultContextWindow;
    while (size < needed && size < maxAutoContextWindow) {
      size *= 2;
    }
    return size;
  }

  /// The `options.num_ctx` sent for [request]: a positive
  /// [LlmRequest.contextWindow] as is; otherwise [contextWindowFor], or the
  /// larger size already used for the model on this server
  /// ([contextSizes], which then remembers the result).
  int contextSizeFor(LlmRequest request) {
    if (request.contextWindow case final size? when size > 0) return size;
    return contextSizes.raise(
      endpoint.baseUrl,
      request.model,
      contextWindowFor(request),
    );
  }

  @override
  Stream<String> streamChat(LlmRequest request) =>
      abortableStream((abortTrigger) async {
        final response = await send(
          'POST',
          resolve('api/chat'),
          abortTrigger: abortTrigger,
          headers: {..._authorization, 'Content-Type': 'application/json'},
          json: _body(request),
        );
        final end = ResponseEnd();
        return responseText(response)
            .transform(const NdjsonDecoder())
            .expand((json) => _deltas(json, end))
            .transform(const ThinkTagFilter())
            .transform(end.check());
      });

  @override
  Future<List<LlmModel>> listModels() async {
    final json = await getJson(resolve('api/tags'), headers: _authorization);
    if (json case {'models': final List<Object?> items}) {
      return sortedModels([
        for (final item in items)
          if (item case {'name': final String name} when name.isNotEmpty)
            LlmModel(id: name),
      ]);
    }
    throw const LlmApiException('Unexpected model list response.');
  }

  /// Loads [model] with an empty `POST {base}/api/generate` carrying the
  /// context size chat requests will use (the remembered one, at least
  /// [defaultContextWindow]) and [keepAlive], so the model is ready (and
  /// stays loaded) before the first translation. Answers true when Ollama
  /// confirmed (`done: true`), false for a blank [model] or on any failure.
  /// Not retried.
  @override
  Future<bool> warmUp(String model) async {
    final name = model.trim();
    if (name.isEmpty) return false;
    // Completed when done so that a timed out request is aborted.
    final abort = Completer<void>();
    try {
      final response = await send(
        'POST',
        resolve('api/generate'),
        abortTrigger: abort.future,
        headers: {..._authorization, 'Content-Type': 'application/json'},
        json: {
          'model': name,
          'stream': false,
          'options': {
            'num_ctx': contextSizes.raise(
              endpoint.baseUrl,
              name,
              defaultContextWindow,
            ),
          },
          'keep_alive': ?_keepAlive,
        },
      );
      final json = tryDecodeJson(await readText(response));
      return json is Map<String, Object?> && json['done'] == true;
    } on Object {
      return false;
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  /// Sent when a key is configured (Ollama behind an authenticating proxy).
  Map<String, String> get _authorization => {
    if (apiKey case final key?) 'Authorization': 'Bearer $key',
  };

  /// [keepAlive] as Ollama takes it: whole seconds, -1 for "forever".
  int? get _keepAlive => switch (keepAlive) {
    null => null,
    final Duration duration when duration.isNegative => -1,
    final Duration duration => duration.inSeconds,
  };

  Map<String, Object?> _body(LlmRequest request) {
    final options = {
      'temperature': ?request.temperature,
      'num_predict': ?request.maxTokens,
      'num_ctx': contextSizeFor(request),
    };
    return {
      'model': request.model,
      'messages': [
        for (final message in request.messages)
          {
            'role': message.role.name,
            'content': message.content,
            if (message.images.isNotEmpty)
              'images': [
                for (final image in message.images) base64Encode(image.bytes),
              ],
          },
      ],
      'stream': true,
      'options': options,
      if (request.jsonOutput) 'format': 'json',
      'keep_alive': ?_keepAlive,
    };
  }

  static Iterable<String> _deltas(Object? json, ResponseEnd end) sync* {
    if (json case {'error': Object()}) {
      throw streamError(json, jsonEncode(json));
    }
    if (json case {'message': {'content': final String content}}
        when content.isNotEmpty) {
      yield content;
    }
    if (json case {'done': true}) {
      if (json['done_reason'] == 'length') {
        end.truncate('length');
      } else {
        end.finish();
      }
    }
  }
}

/// The `num_ctx` each Ollama server and model was last asked for, so that
/// [OllamaClient] never asks for a smaller one within a session: Ollama
/// reloads a model (seconds, sometimes more) whenever `num_ctx` changes,
/// and switching between short translations and long extras (meaning
/// checks, alignment) would otherwise reload it back and forth.
///
/// Held in memory only. Every client shares [shared] unless given another.
class OllamaContextSizes {
  /// The memory shared by clients that were not given their own.
  static final shared = OllamaContextSizes();

  final Map<String, int> _sizes = {};

  /// [wanted], or the larger size already used for [model] on the server
  /// at [baseUrl]; the result is remembered.
  int raise(Uri baseUrl, String model, int wanted) {
    final key = _key(baseUrl, model);
    final size = max(wanted, _sizes[key] ?? 0);
    _sizes[key] = size;
    return size;
  }

  /// The size remembered for [model] on [baseUrl], or null.
  int? sizeOf(Uri baseUrl, String model) => _sizes[_key(baseUrl, model)];

  /// Forgets every size (e.g. when the server was restarted).
  void clear() => _sizes.clear();

  static String _key(Uri baseUrl, String model) {
    var base = baseUrl.toString();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return '$base\n${model.trim()}';
  }
}
