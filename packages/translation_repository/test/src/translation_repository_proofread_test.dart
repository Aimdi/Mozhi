import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

void main() {
  setUpAll(registerTestFallbacks);

  late MockLlmClient client;
  late TranslationRepository repository;
  final claude = aiEngine(claudeConfig);

  setUp(() {
    client = MockLlmClient();
    repository = TranslationRepository(
      mozhiClientFactory: (_) => MockMozhiApiClient(),
      llmClientFactory: (_) => client,
      snapshotInterval: Duration.zero,
    )..updateConfiguration(instances: const [], providers: [claudeConfig]);
  });

  void stubChat(Object json) =>
      when(() => client.chat(any())).thenAnswer((_) async => jsonEncode(json));

  LlmRequest capturedChat() =>
      verify(() => client.chat(captureAny())).captured.single as LlmRequest;

  group('TranslationRepository.proofread', () {
    test('sends the reading level and variety in the prompt', () async {
      stubChat({
        'language': 'en',
        'corrected': 'The colour is nice.',
        'summary': 'British spelling.',
        'edits': [
          {
            'original': 'color',
            'replacement': 'colour',
            'explanation': 'British spelling.',
            'category': 'spelling',
          },
        ],
      });
      final result = await repository.proofread(
        claude,
        'The color is nice.',
        style: WritingStyle.business,
        level: CorrectionLevel.light,
        formality: Formality.preferMore,
        readingLevel: ReadingLevel.b2,
        variety: ProofreadVariety.enGb,
        context: 'memo',
        uiLanguage: 'German',
      );
      expect(result.correctedText, 'The colour is nice.');
      expect(result.edits.single.replacement, 'colour');
      final request = capturedChat();
      expect(request.jsonOutput, isTrue);
      expect(
        request.messages,
        TranslationPrompts.proofread(
          'The color is nice.',
          style: WritingStyle.business,
          level: CorrectionLevel.light,
          formality: Formality.preferMore,
          readingLevel: ReadingLevel.b2,
          variety: ProofreadVariety.enGb,
          context: 'memo',
          uiLanguage: 'German',
        ),
      );
    });

    test("keeps the author's level and variety by default", () async {
      stubChat({'language': 'en', 'corrected': 'Fine.', 'edits': <Object>[]});
      await repository.proofread(claude, 'Fine.');
      final system = capturedChat().messages
          .singleWhere((m) => m.role == LlmRole.system)
          .content;
      expect(system, contains("keep the author's regional variety"));
      expect(system, isNot(contains('Reading level')));
    });
  });
}
