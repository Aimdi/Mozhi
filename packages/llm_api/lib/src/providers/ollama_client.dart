import 'dart:convert';

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
/// start of longer prompts, instructions included.
class OllamaClient extends HttpLlmClient {
  new(super.endpoint, {super.httpClient, super.timeout});

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

  /// Sent when a key is configured (Ollama behind an authenticating proxy).
  Map<String, String> get _authorization => {
    if (apiKey case final key?) 'Authorization': 'Bearer $key',
  };

  static Map<String, Object?> _body(LlmRequest request) {
    final options = {
      'temperature': ?request.temperature,
      'num_predict': ?request.maxTokens,
      'num_ctx': contextWindowFor(request),
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
