import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart';

http.Client sse(String body, {int status = 200}) => MockClient.streaming(
  (req, bodyStream) async {
    await bodyStream.drain<void>();
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
    );
  },
);

Future<void> run(String label, LlmProvider p, String base, String body) async {
  final client = LlmClient(
    LlmEndpoint(provider: p, baseUrl: Uri.parse(base), apiKey: 'k'),
    httpClient: sse(body),
  );
  try {
    final out = await client.chat(
      const LlmRequest(model: 'm', messages: [LlmMessage.user('hi')]),
    );
    print('$label -> OK ${jsonEncode(out)}');
  } on Object catch (e) {
    print('$label -> ERROR $e');
  }
}

Future<void> main() async {
  print('--- ThinkTagFilter');
  for (final s in [
    'Okay, the user wants French.\n</think>\n\nBonjour le monde',
    '<think>x</think>\n\nBonjour',
    'Utilisez la balise <reasoning> pour structurer la réponse.',
    'Le mot <Think> signifie penser. Fin.',
  ]) {
    print('${jsonEncode(s)} => ${jsonEncode(ThinkTagFilter.strip(s))}');
  }

  print('--- truncated streams (no terminal marker)');
  await run('openai no DONE/no finish', LlmProvider.openAiCompatible,
      'http://x/v1',
      'data: {"choices":[{"delta":{"content":"Bonjour, comment"}}]}\n\n');
  await run('openai finish=length', LlmProvider.openAiCompatible, 'http://x/v1',
      'data: {"choices":[{"delta":{"content":"Bonjour, comment"}}]}\n\n'
      'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\ndata: [DONE]\n\n');
  await run('anthropic no message_stop', LlmProvider.anthropic,
      'https://api.anthropic.com/v1',
      'event: message_start\ndata: {"type":"message_start","message":{}}\n\n'
      'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bonjour, comment"}}\n\n');
  await run('anthropic max_tokens', LlmProvider.anthropic,
      'https://api.anthropic.com/v1',
      'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bonjour, comment"}}\n\n'
      'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}\n\n'
      'event: message_stop\ndata: {"type":"message_stop"}\n\n');
  await run('gemini no finishReason', LlmProvider.gemini,
      'https://g/v1beta',
      'data: {"candidates":[{"content":{"parts":[{"text":"Bonjour, comment"}]}}]}\n\n');
  await run('gemini LANGUAGE', LlmProvider.gemini, 'https://g/v1beta',
      'data: {"candidates":[{"finishReason":"LANGUAGE"}]}\n\n');
  await run('gemini MAX_TOKENS', LlmProvider.gemini, 'https://g/v1beta',
      'data: {"candidates":[{"content":{"parts":[{"text":"Bonjour, comment"}]},"finishReason":"MAX_TOKENS"}]}\n\n');
  await run('ollama no done', LlmProvider.ollama, 'http://localhost:11434',
      '{"message":{"role":"assistant","content":"Bonjour, comment"},"done":false}\n');
  await run('ollama done_reason length', LlmProvider.ollama,
      'http://localhost:11434',
      '{"message":{"role":"assistant","content":"Bonjour, comment"},"done":false}\n'
      '{"message":{"role":"assistant","content":""},"done":true,"done_reason":"length"}\n');
  await run('openai orphan </think>', LlmProvider.openAiCompatible,
      'http://x/v1',
      'data: {"choices":[{"delta":{"content":"Okay, translate to French."}}]}\n\n'
      'data: {"choices":[{"delta":{"content":"\\n</think>\\n\\nBonjour"}}]}\n\n'
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
}
