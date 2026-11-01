import 'dart:convert';
import 'dart:typed_data';

import 'package:llm_api/llm_api.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mt_api/mt_api.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'repository/test_helpers.dart';

/// The personal data shield on every path where text goes to an AI model
/// or a machine translation service: with the shield on, nothing the
/// request carries holds the personal data (the model gets tokens and the
/// note about them, and the reply gets the values back); with it off, the
/// text goes as written.
void main() {
  setUpAll(registerTestFallbacks);

  const email = 'jane@x.org';
  const phone = '+49 30 1234567';

  late MockLlmClient claudeClient;
  late MockDeeplClient deepl;
  late TranslationRepository repository;
  final claude = aiEngine(claudeConfig);

  setUp(() {
    claudeClient = MockLlmClient();
    deepl = MockDeeplClient();
    repository =
        allowNetwork(
          TranslationRepository(
            llmClientFactory: (_) => claudeClient,
            deeplClientFactory: (_) => deepl,
            snapshotInterval: Duration.zero,
          ),
        )..updateConfiguration(
          instances: const [],
          providers: const [claudeConfig, deeplConfig],
        );
    addTearDown(repository.dispose);
  });

  /// Everything a captured [request] sends as text.
  String sentText(LlmRequest request) =>
      request.messages.map((message) => message.content).join('\n');

  /// What [request] sends outside the system prompt.
  String userText(LlmRequest request) => [
    for (final message in request.messages)
      if (message.role != LlmRole.system) message.content,
  ].join('\n');

  List<LlmRequest> chats() =>
      verify(() => claudeClient.chat(captureAny())).captured.cast<LlmRequest>();

  List<LlmRequest> streams() =>
      verify(() => claudeClient.streamChat(captureAny())).captured
          .cast<LlmRequest>();

  void stubChat(Object reply) =>
      when(() => claudeClient.chat(any()))
          .thenAnswer((_) async => reply is String ? reply : jsonEncode(reply));

  void stubStream(List<String> deltas) =>
      when(() => claudeClient.streamChat(any()))
          .thenAnswer((_) => Stream.fromIterable(deltas));

  void expectShielded(LlmRequest request) {
    final text = sentText(request);
    expect(text, isNot(contains(email)));
    expect(text, isNot(contains('1234567')));
    expect(userText(request), contains('⟨1⟩'));
    expect(text, contains(TranslationPrompts.maskedPersonalDataNote));
  }

  void expectRaw(LlmRequest request) {
    final text = sentText(request);
    expect(text, contains(email));
    expect(text, isNot(contains(TranslationPrompts.maskedPersonalDataNote)));
    expect(text, isNot(contains('⟨1⟩')));
  }

  void shieldOff() => repository.maskPersonalData = false;

  const request = TranslationRequest(
    text: 'Write to $email or call $phone.',
    source: english,
    target: german,
    options: TranslationOptions(context: 'A note for $email'),
  );
  const translation = 'Schreib an $email oder ruf $phone an.';
  const maskedTranslation = 'Schreib an ⟨1⟩ oder ruf ⟨2⟩ an.';

  group('getAlternatives', () {
    final reply = {
      'description': 'Keeps ⟨1⟩ as it is.',
      'alternatives': [
        {'text': 'Schreiben Sie an ⟨1⟩.', 'explanation': 'formal'},
      ],
    };

    test('masks the request, translation and span', () async {
      stubChat(reply);
      final result = await repository.getAlternatives(
        claude,
        request,
        translation,
        span: 'an $email',
      );
      final sent = chats().single;
      expectShielded(sent);
      expect(sentText(sent), contains(maskedTranslation));
      expect(sentText(sent), contains('an ⟨1⟩'));
      expect(result.description, 'Keeps $email as it is.');
      expect(result.alternatives.single.text, 'Schreiben Sie an $email.');
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubChat(reply);
      await repository.getAlternatives(claude, request, translation);
      expectRaw(chats().single);
    });
  });

  group('getInsights', () {
    final reply = {
      'insights': [
        {
          'source': 'Write to ⟨1⟩',
          'target': 'Schreib an ⟨1⟩',
          'type': 'nuance',
          'explanation': 'Informal',
          'variations': <Object>[],
        },
      ],
    };

    test('masks the texts and locates the insights unmasked', () async {
      stubChat(reply);
      final insights = await repository.getInsights(
        claude,
        request,
        translation,
      );
      expectShielded(chats().single);
      expect(insights.single.targetText, 'Schreib an $email');
      expect(insights.single.sourceText, 'Write to $email');
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubChat(reply);
      await repository.getInsights(claude, request, translation);
      expectRaw(chats().single);
    });
  });

  group('getSuggestions', () {
    final reply = {
      'suggestions': [
        {'label': 'Name ⟨1⟩', 'instruction': 'Spell out ⟨1⟩.', 'icon': 'tune'},
      ],
    };

    test('masks the texts and restores the suggestions', () async {
      stubChat(reply);
      final suggestions = await repository.getSuggestions(
        claude,
        request,
        translation,
      );
      expectShielded(chats().single);
      expect(suggestions.single.instruction, 'Spell out $email.');
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubChat(reply);
      await repository.getSuggestions(claude, request, translation);
      expectRaw(chats().single);
    });
  });

  group('explain', () {
    test('masks the texts and question and restores split tokens', () async {
      stubStream(['Mail ⟨', '1', '⟩ or ⟨2', '⟩. ⟨', '9⟩ ⟨']);
      final text = await repository
          .explain(claude, request, translation, question: 'Is $email ok?')
          .join();
      final sent = streams().single;
      expectShielded(sent);
      expect(sentText(sent), contains('Is ⟨1⟩ ok?'));
      expect(text, 'Mail $email or $phone. ⟨9⟩ ⟨');
    });

    test('holds a token start back until it is complete', () async {
      stubStream([
        'Mail 〈',
        ' ',
        '1',
        ' ',
        '〉, ⟨1',
        '234567⟩ ⟨ 2 ⟨1⟩ ⟨1 2⟩',
        ' ⟨',
        '2',
      ]);
      final deltas = await repository
          .explain(claude, request, translation)
          .toList();
      // Seven digits and a second number are no token's start: they are
      // not held back.
      expect(deltas.join(), 'Mail $email, ⟨1234567⟩ ⟨ 2 $email ⟨1 2⟩ ⟨2');
      expect(deltas, [
        'Mail ',
        '$email, ',
        '⟨1234567⟩ ⟨ 2 $email ⟨1 2⟩',
        ' ',
        '⟨2',
      ]);
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubStream(['Fine.']);
      final text = await repository
          .explain(claude, request, translation)
          .join();
      expectRaw(streams().single);
      expect(text, 'Fine.');
    });
  });

  group('lookUp', () {
    final reply = {
      'word': '⟨1⟩',
      'senses': [
        {'definition': 'An address like ⟨1⟩'},
      ],
    };

    test('masks the word and context and counts what it kept', () async {
      stubChat(reply);
      final entry = await repository.lookUp(
        claude,
        email,
        source: english,
        target: german,
        context: 'Write to $email or call $phone.',
      );
      expectShielded(chats().single);
      expect(entry.word, email);
      expect(entry.senses.single.definition, 'An address like $email');
      expect(entry.maskedPersonalData, 2);
    });

    test('sends the word as written with the shield off', () async {
      shieldOff();
      stubChat(reply);
      final entry = await repository.lookUp(
        claude,
        email,
        source: english,
        target: german,
      );
      expectRaw(chats().single);
      expect(entry.maskedPersonalData, 0);
    });
  });

  group('refine', () {
    test('masks the text, options, translation and instruction', () async {
      stubStream(['Schreiben Sie an ⟨1⟩ oder rufen Sie ⟨2⟩ an.']);
      final results = await repository
          .refine(
            claude,
            request,
            currentTranslation: translation,
            instruction: 'Keep $email.',
          )
          .toList();
      final sent = streams().single;
      expect(sentText(sent), isNot(contains(email)));
      expect(sentText(sent), isNot(contains('1234567')));
      expect(sentText(sent), contains('Keep ⟨1⟩.'));
      expect(sentText(sent), contains('A note for ⟨1⟩'));
      expect(
        results.last.text,
        'Schreiben Sie an $email oder rufen Sie $phone an.',
      );
      expect(results.last.maskedPersonalData, 2);
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubStream(['Schreiben Sie.']);
      await repository
          .refine(
            claude,
            request,
            currentTranslation: translation,
            instruction: 'More formal.',
          )
          .drain<void>();
      expect(sentText(streams().single), contains(email));
    });
  });

  group('translate', () {
    test('masks the context, tone notes and instructions too', () async {
      stubStream(['Schreib an ⟨1⟩ oder ruf ⟨2⟩ an.']);
      final result = await repository
          .translate(
            claude,
            request.copyWith(
              options: request.options.copyWith(
                instructions: 'Keep $phone',
                formality: Formality.more,
                formalityContext: 'to $email',
              ),
            ),
          )
          .last;
      final text = sentText(streams().single);
      expect(text, isNot(contains(email)));
      expect(text, isNot(contains('1234567')));
      expect(text, contains('A note for ⟨1⟩'));
      expect(text, contains('to ⟨1⟩'));
      expect(text, contains('Keep ⟨2⟩'));
      expect(result.text, translation);
    });

    test('sends DeepL its context masked', () async {
      final contexts = <String?>[];
      when(() => deepl.languages(type: any(named: 'type')))
          .thenAnswer((_) async => const []);
      when(
        () => deepl.translateText(
          text: any(named: 'text'),
          targetLang: any(named: 'targetLang'),
          sourceLang: any(named: 'sourceLang'),
          formality: any(named: 'formality'),
          context: any(named: 'context'),
          glossaryId: any(named: 'glossaryId'),
          preserveFormatting: any(named: 'preserveFormatting'),
          tagHandling: any(named: 'tagHandling'),
          modelType: any(named: 'modelType'),
          abortTrigger: any(named: 'abortTrigger'),
        ),
      ).thenAnswer((invocation) async {
        contexts.add(invocation.namedArguments[#context] as String?);
        return const DeeplTranslation(
          text: 'Hallo',
          detectedSourceLanguage: 'EN',
        );
      });
      const plain = TranslationRequest(
        text: 'Hello',
        source: english,
        target: german,
        options: TranslationOptions(context: 'A note for $email'),
      );
      await repository.translate(mtEngine(deeplConfig), plain).drain<void>();
      shieldOff();
      await repository
          .translate(mtEngine(deeplConfig), plain, refresh: true)
          .drain<void>();
      expect(contexts, ['A note for ⟨1⟩', 'A note for $email']);
    });
  });

  group('romanize', () {
    const japanese = Language(code: 'ja', name: 'Japanese');

    test('masks the text and restores the romanization', () async {
      stubChat('Mēru ⟨1⟩ e');
      final text = await repository.romanize(
        claude,
        text: 'メール $email へ',
        language: japanese,
      );
      final sent = chats().single;
      expect(sentText(sent), isNot(contains(email)));
      expect(
        sentText(sent),
        contains(TranslationPrompts.maskedPersonalDataNote),
      );
      expect(text, 'Mēru $email e');
    });

    test('masks long texts before splitting them', () async {
      repository =
          allowNetwork(
            TranslationRepository(
              llmClientFactory: (_) => claudeClient,
              aiChunkThreshold: 10,
            ),
          )..updateConfiguration(
            instances: const [],
            providers: const [claudeConfig],
          );
      when(() => claudeClient.chat(any())).thenAnswer((invocation) async {
        final sent = userText(
          invocation.positionalArguments.single as LlmRequest,
        );
        return sent.contains('⟨1⟩') ? 'Mēru ⟨1⟩' : 'Denwa ⟨2⟩';
      });
      final text = await repository.romanize(
        claude,
        text: 'メール $email\n\n電話 $phone',
        language: japanese,
      );
      for (final sent in chats()) {
        expect(sentText(sent), isNot(contains(email)));
        expect(sentText(sent), isNot(contains('1234567')));
      }
      expect(text, 'Mēru $email\n\nDenwa $phone');
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubChat('Mēru $email e');
      await repository.romanize(
        claude,
        text: 'メール $email へ',
        language: japanese,
      );
      expectRaw(chats().single);
    });
  });

  group('align', () {
    final reply = {
      'pairs': [
        {'source': 'Write to ⟨1⟩', 'target': 'Schreib an ⟨1⟩'},
      ],
    };

    test('masks both texts and aligns the unmasked ones', () async {
      stubChat(reply);
      final spans = await repository.align(
        claude,
        source: request.text,
        translation: translation,
        sourceLanguage: english,
        targetLanguage: german,
      );
      expectShielded(chats().single);
      expect(
        request.text.substring(
          spans.single.sourceStart,
          spans.single.sourceEnd,
        ),
        'Write to $email',
      );
    });

    test('sends the texts as written with the shield off', () async {
      shieldOff();
      stubChat(reply);
      await repository.align(
        claude,
        source: request.text,
        translation: translation,
        sourceLanguage: english,
        targetLanguage: german,
      );
      expectRaw(chats().single);
    });
  });

  group('checkMeaning', () {
    final reply = {
      'back_translation': 'Write to ⟨1⟩ or call ⟨2⟩.',
      'verdict': 'same',
      'issues': <Object>[],
    };

    test('masks both texts and restores the back-translation', () async {
      stubChat(reply);
      final check = await repository.checkMeaning(
        claude,
        source: request.text,
        translation: translation,
        sourceLanguage: english,
        targetLanguage: german,
      );
      expectShielded(chats().single);
      expect(check.backTranslation, 'Write to $email or call $phone.');
    });

    test('sends the texts as written with the shield off', () async {
      shieldOff();
      stubChat(reply);
      await repository.checkMeaning(
        claude,
        source: request.text,
        translation: translation,
        sourceLanguage: english,
        targetLanguage: german,
      );
      expectRaw(chats().single);
    });
  });

  group('proofread', () {
    final reply = {
      'language': 'en',
      'corrected': 'Please write to ⟨1⟩.',
      'edits': [
        {
          'original': 'write to ⟨1⟩',
          'replacement': 'Please write to ⟨1⟩',
          'category': 'style',
        },
      ],
    };

    test('masks the text and context and counts what it kept', () async {
      stubChat(reply);
      final result = await repository.proofread(
        claude,
        'write to $email.',
        context: 'From $phone',
      );
      expectShielded(chats().single);
      expect(result.correctedText, 'Please write to $email.');
      expect(result.edits.single.original, 'write to $email');
      expect(result.maskedPersonalData, 2);
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubChat(reply);
      final result = await repository.proofread(claude, 'write to $email.');
      expectRaw(chats().single);
      expect(result.maskedPersonalData, 0);
    });
  });

  group('rephrase', () {
    test('masks the text and span and restores the alternatives', () async {
      stubChat({
        'alternatives': ['Please write to ⟨1⟩.', 'Write to ⟨1⟩.'],
      });
      final result = await repository.rephrase(
        claude,
        'Hi. Write to $email or call $phone.',
        'Write to $email or call $phone.',
      );
      final sent = chats().single;
      expectShielded(sent);
      expect(userText(sent), contains('<span>\nWrite to ⟨1⟩ or call ⟨2⟩.'));
      expect(result, ['Please write to $email.', 'Write to $email.']);
    });

    test('sends the text as written with the shield off', () async {
      shieldOff();
      stubChat({
        'alternatives': ['Please write to $email.'],
      });
      await repository.rephrase(claude, 'Write to $email.', 'Write to $email.');
      expectRaw(chats().single);
    });
  });

  group('translateImage', () {
    test('masks the options; the image goes as it is', () async {
      stubChat('Schreib an ⟨1⟩');
      final result = await repository.translateImage(
        claude,
        Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/png',
        source: english,
        target: german,
        options: request.options,
      );
      final sent = chats().single;
      expect(sentText(sent), contains('A note for ⟨1⟩'));
      expect(sentText(sent), isNot(contains(email)));
      expect(result.translatedText, 'Schreib an $email');
    });

    test('sends the options as written with the shield off', () async {
      shieldOff();
      stubChat('Hallo');
      await repository.translateImage(
        claude,
        Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/png',
        source: english,
        target: german,
        options: request.options,
      );
      expectRaw(chats().single);
    });
  });

  test('a text without personal data gets no note', () async {
    stubChat({'description': 'x', 'alternatives': <Object>[]});
    await repository.getAlternatives(
      claude,
      const TranslationRequest(text: 'Hello', source: english, target: german),
      'Hallo',
    );
    expect(
      sentText(chats().single),
      isNot(contains(TranslationPrompts.maskedPersonalDataNote)),
    );
  });
}
