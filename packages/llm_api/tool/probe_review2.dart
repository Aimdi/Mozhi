import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart';

Future<void> rawServer(String label, String headers, String body) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) async {
    socket.listen((_) {});
    socket.write('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n$headers\r\n');
    socket.write(body);
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await socket.close();
  });
  final client = LlmClient(
    LlmEndpoint(
      provider: LlmProvider.openAiCompatible,
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1'),
    ),
  );
  try {
    final out = await client.chat(
      const LlmRequest(model: 'm', messages: [LlmMessage.user('hi')]),
    );
    print('$label -> OK ${jsonEncode(out)}');
  } on Object catch (e) {
    print('$label -> ERROR $e');
  }
  client.close();
  await server.close();
}

String chunk(String s) {
  final b = utf8.encode(s);
  return '${b.length.toRadixString(16)}\r\n$s\r\n';
}

Future<void> main() async {
  const ev = 'data: {"choices":[{"delta":{"content":"Bonjour, comment"}}]}\n\n';
  await rawServer('io chunked, truncated (no 0-chunk)',
      'Transfer-Encoding: chunked\r\n', chunk(ev));
  await rawServer('io close-delimited, no [DONE]', 'Connection: close\r\n', ev);
  await rawServer('io chunked, clean end, no [DONE]',
      'Transfer-Encoding: chunked\r\n', '${chunk(ev)}0\r\n\r\n');

  // Anthropic effort rejected on a model without effort support.
  var calls = 0;
  final mock = MockClient((req) async {
    calls++;
    final body = jsonDecode(req.body) as Map;
    if (body.containsKey('output_config')) {
      return http.Response(
        jsonEncode({
          'type': 'error',
          'error': {
            'type': 'invalid_request_error',
            'message': 'This model does not support the effort parameter.',
          },
        }),
        400,
      );
    }
    return http.Response('event: message_stop\ndata: {"type":"message_stop"}\n\n', 200);
  });
  final a = LlmClient(
    LlmEndpoint(
      provider: LlmProvider.anthropic,
      baseUrl: Uri.parse('https://api.anthropic.com/v1'),
      apiKey: 'k',
    ),
    httpClient: mock,
  );
  try {
    await a.chat(const LlmRequest(
      model: 'claude-haiku-4-5-20251001',
      messages: [LlmMessage.user('hi')],
      effort: 'low',
    ));
    print('anthropic effort -> OK after $calls calls');
  } on Object catch (e) {
    print('anthropic effort -> ERROR $e after $calls calls');
  }

  // Does onCancel fire (abort trigger complete) when send() times out?
  Future<void>? trigger;
  final hang = MockClient.streaming((req, body) async {
    trigger = (req as http.Abortable).abortTrigger;
    await body.drain<void>();
    return Completer<http.StreamedResponse>().future; // never responds
  });
  final o = LlmClient(
    LlmEndpoint(
      provider: LlmProvider.openAiCompatible,
      baseUrl: Uri.parse('http://x/v1'),
    ),
    httpClient: hang,
    timeout: const Duration(milliseconds: 100),
  );
  var aborted = false;
  try {
    await o.chat(const LlmRequest(model: 'm', messages: [LlmMessage.user('x')]));
  } on Object catch (e) {
    print('timeout -> $e');
  }
  unawaited(trigger?.then((_) => aborted = true));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  print('abort trigger completed after timeout: $aborted');
}
