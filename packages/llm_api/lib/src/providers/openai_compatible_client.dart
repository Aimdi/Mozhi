import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:llm_api/src/llm_exception.dart';
import 'package:llm_api/src/models.dart';
import 'package:llm_api/src/providers/error_parsing.dart';
import 'package:llm_api/src/providers/http_llm_client.dart';
import 'package:llm_api/src/providers/response_end.dart';
import 'package:llm_api/src/streaming/sse_decoder.dart';
import 'package:llm_api/src/think_filter.dart';

/// Client for OpenAI-compatible Chat Completions APIs
/// ([LlmProvider.openAiCompatible]).
///
/// Streams `POST {base}/chat/completions` (SSE) and lists models with
/// `GET {base}/models`. Content is piped through [ThinkTagFilter]; separate
/// reasoning fields (`reasoning_content`, `reasoning`) are ignored.
///
/// The response is complete at `[DONE]` or at any `finish_reason`
/// (some servers send one but no `[DONE]`); `finish_reason: "length"` raises
/// [LlmTruncatedException] and a body that ends without either raises
/// [LlmInterruptedException].
class OpenAiCompatibleClient extends HttpLlmClient {
  new(super.endpoint, {super.httpClient, super.timeout, super.retryPolicy});

  @override
  Stream<String> streamChat(LlmRequest request) =>
      abortableStream((abortTrigger) async {
        Future<http.StreamedResponse> post({required bool withOptions}) => send(
          'POST',
          resolve('chat/completions'),
          abortTrigger: abortTrigger,
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
            ..._authorization,
          },
          json: _body(request, withOptions: withOptions),
        );

        http.StreamedResponse response;
        try {
          response = await post(withOptions: true);
        } on LlmApiException catch (error) {
          // Many local servers reject `response_format` / `reasoning_effort`;
          // retry once without them.
          final sentOptions = request.jsonOutput || request.effort != null;
          if (error.statusCode != 400 || !sentOptions) rethrow;
          response = await post(withOptions: false);
        }
        final end = ResponseEnd();
        return sseEvents(response)
            .takeWhile((event) {
              if (event.data.trim() != '[DONE]') return true;
              end.finish();
              return false;
            })
            .expand((event) => _deltas(event, end))
            .transform(const ThinkTagFilter())
            .transform(end.check());
      });

  @override
  Future<List<LlmModel>> listModels() async {
    final json = await getJson(resolve('models'), headers: _authorization);
    final items = switch (json) {
      {'data': final List<Object?> items} => items,
      {'models': final List<Object?> items} => items,
      final List<Object?> items => items,
      _ => throw const LlmApiException('Unexpected model list response.'),
    };
    return sortedModels(items.map(_model).nonNulls);
  }

  Map<String, String> get _authorization => {
    if (apiKey case final key?) 'Authorization': 'Bearer $key',
  };

  static Map<String, Object?> _body(
    LlmRequest request, {
    required bool withOptions,
  }) => {
    'model': request.model,
    'messages': [for (final message in request.messages) _message(message)],
    'stream': true,
    'temperature': ?request.temperature,
    'max_tokens': ?request.maxTokens,
    if (withOptions) 'reasoning_effort': ?request.effort,
    if (withOptions && request.jsonOutput)
      'response_format': {'type': 'json_object'},
  };

  static Map<String, Object?> _message(LlmMessage message) => {
    'role': message.role.name,
    'content': message.images.isEmpty
        ? message.content
        : [
            if (message.content.isNotEmpty)
              {'type': 'text', 'text': message.content},
            for (final image in message.images)
              {
                'type': 'image_url',
                'image_url': {
                  'url':
                      'data:${image.mimeType};base64,'
                      '${base64Encode(image.bytes)}',
                },
              },
          ],
  };

  static Iterable<String> _deltas(SseEvent event, ResponseEnd end) sync* {
    final data = event.data.trim();
    if (data.isEmpty) return;
    final json = jsonDecode(data);
    if (json case {'error': Object()}) throw streamError(json, data);
    if (json case {'choices': [final Map<String, Object?> choice, ...]}) {
      if (choice case {'delta': {'content': final String content}}
          when content.isNotEmpty) {
        yield content;
      }
      switch (choice['finish_reason']) {
        case 'content_filter':
          throw const LlmRefusalException(
            "The response was blocked by the provider's content filter.",
            category: 'content_filter',
          );
        case 'length':
          end.truncate('length');
        case String():
          end.finish();
      }
    }
  }

  static LlmModel? _model(Object? item) => switch (item) {
    final String id when id.isNotEmpty => LlmModel(id: id),
    final Map<String, Object?> item => _modelFromJson(item),
    _ => null,
  };

  /// `{"id": ..., "name"?: ...}` (OpenAI, OpenRouter) or `{"name": ...}`.
  static LlmModel? _modelFromJson(Map<String, Object?> item) {
    final (id, name) = switch (item) {
      {'id': final String id} => (id, item['name']),
      {'name': final String id} => (id, null),
      _ => ('', null),
    };
    if (id.isEmpty) return null;
    return LlmModel(
      id: id,
      displayName: name is String && name != id ? name : null,
      contextWindow: _contextWindow(item),
    );
  }

  /// Context sizes as reported by OpenRouter / Groq / vLLM / LM Studio.
  static int? _contextWindow(Map<String, Object?> item) => switch (item) {
    {'context_length': final int size} => size,
    {'context_window': final int size} => size,
    {'max_model_len': final int size} => size,
    {'max_context_length': final int size} => size,
    _ => null,
  };
}
