import 'dart:convert';

import 'package:llm_api/src/llm_exception.dart';
import 'package:llm_api/src/models.dart';
import 'package:llm_api/src/providers/error_parsing.dart';
import 'package:llm_api/src/providers/http_llm_client.dart';
import 'package:llm_api/src/providers/response_end.dart';
import 'package:llm_api/src/streaming/sse_decoder.dart';

/// Client for the Google Gemini API ([LlmProvider.gemini]).
///
/// Streams `POST {base}/models/{model}:streamGenerateContent?alt=sse` and
/// lists models with `GET {base}/models`. Thought parts are ignored.
///
/// The response is complete at `finishReason: "STOP"`. `MAX_TOKENS` raises
/// [LlmTruncatedException], the [refusalFinishReasons] raise
/// [LlmRefusalException] and any other finish reason (`LANGUAGE`, `OTHER`,
/// ...) raises [LlmStoppedException]. A body that ends without a finish reason
/// raises [LlmInterruptedException].
class GeminiClient extends HttpLlmClient {
  new(super.endpoint, {super.httpClient, super.timeout, super.retryPolicy});

  /// `finishReason`s that mean the response was blocked.
  static const refusalFinishReasons = {
    'SAFETY',
    'PROHIBITED_CONTENT',
    'BLOCKLIST',
    'SPII',
    'RECITATION',
  };

  @override
  Stream<String> streamChat(LlmRequest request) =>
      abortableStream((abortTrigger) async {
        final response = await send(
          'POST',
          resolve('${_modelPath(request.model)}:streamGenerateContent', {
            'alt': 'sse',
          }),
          abortTrigger: abortTrigger,
          headers: {..._headers, 'Content-Type': 'application/json'},
          json: _body(request),
        );
        final end = ResponseEnd();
        return sseEvents(response)
            .expand((event) => _deltas(event, end))
            .transform(end.check());
      });

  @override
  Future<List<LlmModel>> listModels() async {
    final json = await getJson(
      resolve('models', {'pageSize': '1000'}),
      headers: _headers,
    );
    if (json case {'models': final List<Object?> items}) {
      return sortedModels([
        for (final item in items)
          if (item case {'name': final String name}
              when name.isNotEmpty && _supportsGenerateContent(item))
            LlmModel(
              id: name.startsWith('models/') ? name.substring(7) : name,
              displayName: switch (item['displayName']) {
                final String name => name,
                _ => null,
              },
              contextWindow: switch (item['inputTokenLimit']) {
                final int tokens => tokens,
                _ => null,
              },
            ),
      ]);
    }
    throw const LlmApiException('Unexpected model list response.');
  }

  Map<String, String> get _headers => {'x-goog-api-key': ?apiKey};

  /// `models/<id>`, or the name as given when it already names a resource
  /// (e.g. `models/...`, `tunedModels/...`).
  static String _modelPath(String model) =>
      model.contains('/') ? model : 'models/$model';

  /// Models without `supportedGenerationMethods` are assumed to chat.
  static bool _supportsGenerateContent(Map<Object?, Object?> item) =>
      switch (item['supportedGenerationMethods']) {
        final List<Object?> methods => methods.contains('generateContent'),
        _ => true,
      };

  static Map<String, Object?> _body(LlmRequest request) {
    final system = joinSystemMessages(request.messages);
    final generationConfig = {
      'temperature': ?request.temperature,
      'maxOutputTokens': ?request.maxTokens,
      if (request.jsonOutput) 'responseMimeType': 'application/json',
    };
    return {
      'contents': [
        for (final message in request.messages)
          if (message.role != LlmRole.system) _content(message),
      ],
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      if (generationConfig.isNotEmpty) 'generationConfig': generationConfig,
    };
  }

  static Map<String, Object?> _content(LlmMessage message) => {
    'role': message.role == LlmRole.assistant ? 'model' : 'user',
    'parts': [
      // Gemini rejects empty text parts; an image-only message has none.
      if (message.content.isNotEmpty || message.images.isEmpty)
        {'text': message.content},
      for (final image in message.images)
        {
          'inlineData': {
            'mimeType': image.mimeType,
            'data': base64Encode(image.bytes),
          },
        },
    ],
  };

  static Iterable<String> _deltas(SseEvent event, ResponseEnd end) sync* {
    final data = event.data.trim();
    if (data.isEmpty) return;
    final json = jsonDecode(data);
    if (json case {'error': Object()}) throw streamError(json, data);
    if (json case {'promptFeedback': {'blockReason': final String reason}}) {
      throw LlmRefusalException(
        'Gemini blocked the request ($reason).',
        category: reason,
      );
    }
    if (json case {'candidates': [final Map<String, Object?> candidate, ...]}) {
      if (candidate case {'content': {'parts': final List<Object?> parts}}) {
        for (final part in parts) {
          if (part case {'text': final String text}
              when text.isNotEmpty && part['thought'] != true) {
            yield text;
          }
        }
      }
      switch (candidate['finishReason']) {
        case null:
          break;
        case 'STOP':
          end.finish();
        case 'MAX_TOKENS':
          end.truncate('MAX_TOKENS');
        case final String reason when refusalFinishReasons.contains(reason):
          throw LlmRefusalException(
            'Gemini blocked the response ($reason).',
            category: reason,
          );
        case 'LANGUAGE':
          throw const LlmStoppedException(
            'Gemini does not support this language.',
            reason: 'LANGUAGE',
          );
        case final reason:
          throw LlmStoppedException(
            'Gemini stopped without completing the response ($reason).',
            reason: reason is String ? reason : null,
          );
      }
    }
  }
}
