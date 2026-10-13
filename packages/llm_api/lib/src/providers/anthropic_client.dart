import 'dart:convert';

import 'package:llm_api/src/llm_exception.dart';
import 'package:llm_api/src/models.dart';
import 'package:llm_api/src/providers/error_parsing.dart';
import 'package:llm_api/src/providers/http_llm_client.dart';
import 'package:llm_api/src/streaming/sse_decoder.dart';

/// Client for the Anthropic Messages API ([LlmProvider.anthropic]).
///
/// Streams `POST {base}/messages` (SSE) and lists models with
/// `GET {base}/models`. Only `text_delta`s are emitted; thinking and other
/// block types (including server-side `fallback` markers) are ignored.
class AnthropicClient extends HttpLlmClient {
  new(super.endpoint, {super.httpClient, super.timeout});

  /// Value of the `anthropic-version` header.
  static const apiVersion = '2023-06-01';

  /// `max_tokens` sent when [LlmRequest.maxTokens] is null.
  static const defaultMaxTokens = 64000;

  /// `max_tokens` used for the retry when the API rejects the requested one.
  static const fallbackMaxTokens = 8192;

  /// Beta enabling `"fallbacks": "default"` (server-side refusal fallback).
  static const fallbackBeta = 'server-side-fallback-2026-07-01';

  /// Models that get server-side refusal fallback on `api.anthropic.com`.
  static const fallbackModels = {
    'claude-fable-5-1',
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
  };

  /// `error.type` of streamed / HTTP errors -> HTTP status.
  static const _errorStatus = {
    'invalid_request_error': 400,
    'authentication_error': 401,
    'billing_error': 402,
    'permission_error': 403,
    'not_found_error': 404,
    'request_too_large': 413,
    'rate_limit_error': 429,
    'api_error': 500,
    'timeout_error': 504,
    'overloaded_error': 529,
  };

  @override
  Stream<String> streamChat(LlmRequest request) => abortableStream((
    abortTrigger,
  ) async {
    var maxTokens = request.maxTokens ?? defaultMaxTokens;
    var fallbacks =
        endpoint.baseUrl.host == 'api.anthropic.com' &&
        fallbackModels.contains(request.model);
    while (true) {
      try {
        final response = await send(
          'POST',
          resolve('messages'),
          abortTrigger: abortTrigger,
          headers: {
            ..._headers,
            'content-type': 'application/json',
            if (fallbacks) 'anthropic-beta': fallbackBeta,
          },
          json: _body(request, maxTokens: maxTokens, fallbacks: fallbacks),
        );
        return sseEvents(response)
            .map(_decode)
            .takeWhile((event) => event.type != 'message_stop')
            .expand(_deltas);
      } on LlmApiException catch (error) {
        if (error.statusCode != 400) rethrow;
        final message = error.message.toLowerCase();
        if (maxTokens != fallbackMaxTokens && message.contains('max_tokens')) {
          maxTokens = fallbackMaxTokens;
        } else if (fallbacks &&
            (message.contains('fallbacks') ||
                message.contains('anthropic-beta'))) {
          fallbacks = false;
        } else {
          rethrow;
        }
      }
    }
  });

  @override
  Future<List<LlmModel>> listModels() async {
    final json = await getJson(
      resolve('models', {'limit': '1000'}),
      headers: _headers,
    );
    if (json case {'data': final List<Object?> items}) {
      return sortedModels([
        for (final item in items)
          if (item case {'id': final String id} when id.isNotEmpty)
            LlmModel(
              id: id,
              displayName: switch (item['display_name']) {
                final String name => name,
                _ => null,
              },
              contextWindow: switch (item['max_input_tokens']) {
                final int tokens => tokens,
                _ => null,
              },
            ),
      ]);
    }
    throw const LlmApiException('Unexpected model list response.');
  }

  Map<String, String> get _headers => {
    'x-api-key': ?apiKey,
    'anthropic-version': apiVersion,
    // Required for CORS when called from a browser (web build).
    'anthropic-dangerous-direct-browser-access': 'true',
  };

  static Map<String, Object?> _body(
    LlmRequest request, {
    required int maxTokens,
    required bool fallbacks,
  }) {
    final system = joinSystemMessages(request.messages);
    return {
      'model': request.model,
      'max_tokens': maxTokens,
      'stream': true,
      if (system.isNotEmpty) 'system': system,
      'messages': [
        for (final message in request.messages)
          if (message.role != LlmRole.system) _message(message),
      ],
      'temperature': ?request.temperature,
      if (request.effort case final effort?)
        'output_config': {'effort': effort},
      if (fallbacks) 'fallbacks': 'default',
    };
  }

  static Map<String, Object?> _message(LlmMessage message) => {
    'role': message.role.name,
    'content': message.images.isEmpty
        ? message.content
        : [
            for (final image in message.images)
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': image.mimeType,
                  'data': base64Encode(image.bytes),
                },
              },
            if (message.content.isNotEmpty)
              {'type': 'text', 'text': message.content},
          ],
  };

  /// Event type (from the JSON `type`, else the SSE `event:` name) and data.
  static _Event _decode(SseEvent event) {
    final raw = event.data.trim();
    final json = raw.isEmpty ? null : jsonDecode(raw);
    final data = json is Map<String, Object?>
        ? json
        : const <String, Object?>{};
    final type = switch (data['type']) {
      final String type => type,
      _ => event.event,
    };
    return (type: type, data: data, raw: raw);
  }

  static Iterable<String> _deltas(_Event event) sync* {
    switch (event.type) {
      case 'content_block_delta':
        if (event.data
            case {'delta': {'type': 'text_delta', 'text': final String text}}
            when text.isNotEmpty) {
          yield text;
        }
      case 'message_delta':
        if (event.data case {'delta': {'stop_reason': 'refusal'}}) {
          throw LlmRefusalException(
            'Claude declined to respond to this request.',
            category: _refusalCategory(event.data),
          );
        }
      case 'error':
        final error = streamError(event.data, event.raw);
        throw LlmApiException(
          error.message,
          statusCode: switch (event.data) {
            {'error': {'type': final String type}} => _errorStatus[type],
            _ => null,
          },
          body: error.body,
        );
    }
  }

  /// `stop_details.category`, found next to `stop_reason` in the delta (or
  /// at the top level of the event).
  static String? _refusalCategory(Map<String, Object?> data) => switch (data) {
    {'delta': {'stop_details': {'category': final String category}}} =>
      category,
    {'stop_details': {'category': final String category}} => category,
    _ => null,
  };
}

typedef _Event = ({String? type, Map<String, Object?> data, String raw});
