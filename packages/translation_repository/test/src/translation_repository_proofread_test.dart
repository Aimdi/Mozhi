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
    allowNetwork(repository);
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
      expect(system, isNot(contains('Tone:')));
    });

    test('sends the tone in the prompt', () async {
      stubChat({'language': 'en', 'corrected': 'Fine!', 'edits': <Object>[]});
      await repository.proofread(
        claude,
        'Fine.',
        tone: WritingTone.enthusiastic,
      );
      expect(
        capturedChat().messages,
        TranslationPrompts.proofread('Fine.', tone: WritingTone.enthusiastic),
      );
    });
  });

  group('TranslationRepository.rephrase', () {
    const text = 'Hello. The report is late.';
    const span = 'The report is late.';

    test('sends the rephrase prompt and parses the alternatives', () async {
      stubChat({
        'alternatives': [
          'The report is overdue.',
          'The report is late.',
          'The report is overdue.',
          'We are still waiting for the report.',
          'The report has not arrived.',
        ],
      });
      final alternatives = await repository.rephrase(
        claude,
        text,
        span,
        style: WritingStyle.business,
        tone: WritingTone.diplomatic,
        formality: Formality.more,
        uiLanguage: 'German',
      );
      expect(alternatives, [
        'The report is overdue.',
        'We are still waiting for the report.',
        'The report has not arrived.',
      ]);
      final request = capturedChat();
      expect(request.jsonOutput, isTrue);
      expect(
        request.messages,
        TranslationPrompts.rephrase(
          text,
          span,
          style: WritingStyle.business,
          tone: WritingTone.diplomatic,
          formality: Formality.more,
          uiLanguage: 'German',
        ),
      );
    });

    test('keeps at most count alternatives', () async {
      stubChat(['A.', 'B.', 'C.']);
      expect(await repository.rephrase(claude, text, span, count: 2), [
        'A.',
        'B.',
      ]);
      expect(_system(capturedChat()), contains('give 2 alternative phrasings'));
    });

    test('asks again once for valid JSON', () async {
      final replies = [
        'Sorry, here you go: none',
        '["The report is overdue."]',
      ];
      when(() => client.chat(any()))
          .thenAnswer((_) async => replies.removeAt(0));
      expect(await repository.rephrase(claude, text, span), [
        'The report is overdue.',
      ]);
      verify(() => client.chat(any())).called(2);
    });

    test('rejects a blank span', () {
      expect(
        () => repository.rephrase(claude, text, '  '),
        throwsArgumentError,
      );
      verifyNever(() => client.chat(any()));
    });
  });
}

String _system(LlmRequest request) =>
    request.messages.singleWhere((m) => m.role == LlmRole.system).content;
