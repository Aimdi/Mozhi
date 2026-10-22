import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llm_api/llm_api.dart' show LlmClient;
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_ocr.dart';
import '../helpers/helpers.dart';

const _provider = AiProviderConfig(
  id: 'mock',
  name: 'Mock AI',
  provider: LlmProvider.openAiCompatible,
  baseUrl: 'http://127.0.0.1:8787/v1',
  model: 'mock-translator-8b',
);

const _engine = TranslationEngine(
  id: 'ai:mock',
  kind: EngineKind.ai,
  name: 'Mock AI',
  providerId: 'mock',
);

/// The translation answer of the web E2E suite's mock AI
/// (`e2e/mock_server.py`, `llm_answer`): a thinking block, then the text
/// between `<source>` tags prefixed with `[AI→<target>] `, streamed in
/// pieces of four characters as OpenAI-compatible server-sent events.
Future<http.StreamedResponse> _mockAi(
  http.BaseRequest request,
  http.ByteStream body,
) async {
  final json =
      jsonDecode(utf8.decode(await body.toBytes())) as Map<String, Object?>;
  final messages = (json['messages']! as List).cast<Map<String, Object?>>();
  String content(Map<String, Object?> message) => switch (message['content']) {
    final String text => text,
    final List<Object?> parts =>
      parts
          .whereType<Map<String, Object?>>()
          .map((part) => part['text'] as String? ?? '')
          .join(' '),
    _ => '',
  };
  final system = messages
      .where((m) => m['role'] == 'system')
      .map(content)
      .join('\n');
  final user = content(messages.last);
  final source = RegExp(
    r'<source>\s*(.*?)\s*</source>',
    dotAll: true,
  ).firstMatch(user)?.group(1);
  final target =
      RegExp(r"into ([A-Z][\w\- ()']+)").firstMatch(system)?.group(1)?.trim() ??
      'French';
  final answer =
      '<think>The user wants a translation. Let me think.</think>\n'
      '[AI→$target] ${source ?? user}';
  String event(String piece) => jsonEncode({
    'choices': [
      {
        'delta': {'content': piece},
        'index': 0,
      },
    ],
  });
  String sse(String data) => 'data: $data\n\n';
  final events = [
    for (var i = 0; i < answer.length; i += 4)
      sse(event(answer.substring(i, math.min(i + 4, answer.length)))),
    sse('[DONE]'),
  ];
  return http.StreamedResponse(
    Stream.fromIterable(events.map(utf8.encode)),
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}

TextParagraph _paragraph(String text, double top) =>
    TextParagraph(text: text, box: Rect.fromLTWH(10, top, 300, 40));

// The paragraphs of a photo survive one request to the web E2E suite's
// mock AI through the real repository (prompt, streaming, parsing).
void main() {
  setUpAll(registerImageTranslateFallbacks);

  test('the mock AI keeps the paragraphs apart', () async {
    final requests = <http.BaseRequest>[];
    final client = MockClient.streaming((request, body) {
      requests.add(request);
      return _mockAi(request, body);
    });
    final repository =
        TranslationRepository(
            llmClientFactory: (endpoint) =>
                LlmClient(endpoint, httpClient: client),
            snapshotInterval: Duration.zero,
          )
          ..updateConfiguration(
            instances: const [],
            providers: const [_provider],
          )
          ..updatePrivacy(
            mode: PrivacyMode.online,
            consentedProviders: const ['mock'],
          );
    final layout = TextLayout(
      width: 400,
      height: 300,
      paragraphs: [
        _paragraph('Öffnungszeiten', 10),
        _paragraph('Montag bis Freitag von 9 bis 18 Uhr.\nSamstag zu', 60),
        _paragraph('Bitte klingeln', 120),
        _paragraph('Kasse', 180),
      ],
    );
    final data = FakeOcrData(text: 'raw')
      ..installed = {'deu': 1}
      ..layout = layout;
    final cubit = ImageTranslateCubit(
      repository: repository,
      picker: FakeImagePickerService(),
      encoder: FakeImageEncoder(),
      recognizer: data,
      engines: const [_engine],
      providers: const [_provider],
      translateEngine: _engine,
      source: german,
      target: english,
    );
    addTearDown(cubit.close);

    await cubit.setImage(jpegImage);

    expect(cubit.state.status, ImageTranslateStatus.success);
    expect(requests, hasLength(1));
    expect(cubit.state.result?.translatedParagraphs, [
      '[AI→English] Öffnungszeiten',
      'Montag bis Freitag von 9 bis 18 Uhr.\nSamstag zu',
      'Bitte klingeln',
      'Kasse',
    ]);
    expect(cubit.state.showsOverlay, isTrue);
  });
}
