import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

/// Asserts value equality: [a] equals [b] (same hash) and differs from
/// every element of [different].
void expectValueEquality(Object a, Object b, List<Object> different) {
  expect(a, equals(b));
  expect(a.hashCode, b.hashCode);
  for (final other in different) {
    expect(a, isNot(equals(other)));
  }
  expect(a, isNot(equals(Object())));
}

void main() {
  group('AI feature models', () {
    test('AlternativeTranslations', () {
      expectValueEquality(
        const AlternativeTranslations(
          description: 'd',
          alternatives: [Alternative(text: 'a', explanation: 'e')],
        ),
        const AlternativeTranslations(
          description: 'd',
          alternatives: [Alternative(text: 'a', explanation: 'e')],
        ),
        [
          const AlternativeTranslations(description: 'x', alternatives: []),
          const AlternativeTranslations(
            description: 'd',
            alternatives: [Alternative(text: 'b')],
          ),
        ],
      );
    });

    test('Alternative', () {
      expectValueEquality(
        const Alternative(text: 'a'),
        const Alternative(text: 'a'),
        [
          const Alternative(text: 'b'),
          const Alternative(text: 'a', explanation: 'x'),
        ],
      );
    });

    test('WordInsight', () {
      const insight = WordInsight(
        sourceText: 's',
        targetText: 't',
        type: 'idiom',
        explanation: 'e',
        variations: [Alternative(text: 'v')],
      );
      expect(
        const WordInsight(sourceText: 's', targetText: 't').type,
        'nuance',
      );
      expectValueEquality(
        insight,
        const WordInsight(
          sourceText: 's',
          targetText: 't',
          type: 'idiom',
          explanation: 'e',
          variations: [Alternative(text: 'v')],
        ),
        [
          const WordInsight(sourceText: 'x', targetText: 't'),
          const WordInsight(
            sourceText: 's',
            targetText: 't',
            type: 'idiom',
            explanation: 'e',
          ),
        ],
      );
    });

    test('RefinementSuggestion', () {
      expectValueEquality(
        const RefinementSuggestion(label: 'l', instruction: 'i'),
        const RefinementSuggestion(label: 'l', instruction: 'i'),
        [
          const RefinementSuggestion(label: 'l', instruction: 'j'),
          const RefinementSuggestion(label: 'l', instruction: 'i', icon: 'x'),
        ],
      );
      expect(RefinementSuggestion.defaults, hasLength(6));
      expect(
        RefinementSuggestion.defaults.map((s) => s.icon),
        containsAll(['formal', 'casual', 'shorter', 'simplify', 'fluent']),
      );
    });

    test('DictionaryEntry and parts', () {
      const entry = DictionaryEntry(
        word: 'run',
        pronunciation: '/rʌn/',
        partsOfSpeech: ['verb'],
        senses: [
          DictionarySense(
            definition: 'move fast',
            partOfSpeech: 'verb',
            translations: ['courir'],
            usage: 'common',
          ),
        ],
        examples: [
          DictionaryExample(source: 'I run.', translation: 'Je cours.'),
        ],
        synonyms: ['sprint'],
        etymology: 'Old English',
        notes: 'n',
      );
      expectValueEquality(
        entry,
        const DictionaryEntry(
          word: 'run',
          pronunciation: '/rʌn/',
          partsOfSpeech: ['verb'],
          senses: [
            DictionarySense(
              definition: 'move fast',
              partOfSpeech: 'verb',
              translations: ['courir'],
              usage: 'common',
            ),
          ],
          examples: [
            DictionaryExample(source: 'I run.', translation: 'Je cours.'),
          ],
          synonyms: ['sprint'],
          etymology: 'Old English',
          notes: 'n',
        ),
        [
          const DictionaryEntry(word: 'run'),
          const DictionaryEntry(word: 'walk', synonyms: ['sprint']),
        ],
      );
      expectValueEquality(
        const DictionarySense(definition: 'd'),
        const DictionarySense(definition: 'd'),
        [
          const DictionarySense(definition: 'd', translations: ['x']),
        ],
      );
      expectValueEquality(
        const DictionaryExample(source: 's'),
        const DictionaryExample(source: 's'),
        [const DictionaryExample(source: 's', translation: 't')],
      );
    });

    test('ProofreadResult and ProofreadEdit', () {
      expectValueEquality(
        const ProofreadResult(
          correctedText: 'c',
          edits: [ProofreadEdit(original: 'o', replacement: 'r')],
          detectedLanguage: 'en',
          summary: 's',
        ),
        const ProofreadResult(
          correctedText: 'c',
          edits: [ProofreadEdit(original: 'o', replacement: 'r')],
          detectedLanguage: 'en',
          summary: 's',
        ),
        [
          const ProofreadResult(correctedText: 'c'),
          const ProofreadResult(
            correctedText: 'c',
            edits: [
              ProofreadEdit(
                original: 'o',
                replacement: 'r',
                category: 'spelling',
              ),
            ],
            detectedLanguage: 'en',
            summary: 's',
          ),
        ],
      );
      expect(
        const ProofreadEdit(original: 'o', replacement: 'r').category,
        'grammar',
      );
    });

    test('DetectedLanguage', () {
      expectValueEquality(
        const DetectedLanguage(code: 'fr', alternatives: ['ca']),
        const DetectedLanguage(code: 'fr', alternatives: ['ca']),
        [
          const DetectedLanguage(code: 'fr'),
          const DetectedLanguage(
            code: 'fr',
            isMixed: true,
            alternatives: ['ca'],
          ),
          const DetectedLanguage(
            code: 'fr',
            isUncertain: true,
            alternatives: ['ca'],
          ),
        ],
      );
    });

    test('ImageTranslationResult', () {
      expectValueEquality(
        const ImageTranslationResult(
          translatedImage: [1, 2, 3],
          translatedText: 't',
        ),
        const ImageTranslationResult(
          translatedImage: [1, 2, 3],
          translatedText: 't',
        ),
        [
          const ImageTranslationResult(translatedText: 't'),
          const ImageTranslationResult(
            translatedImage: [1, 2],
            translatedText: 't',
          ),
        ],
      );
      expectValueEquality(
        const ImageTranslationResult(),
        const ImageTranslationResult(),
        [const ImageTranslationResult(notes: 'n')],
      );
    });
  });

  group(TranslationResult, () {
    const result = TranslationResult(
      engineId: 'ai:1',
      engineName: 'Claude',
      text: 'Bonjour',
      isComplete: false,
      detectedSource: 'en',
      sourceTransliteration: 'src',
      targetTransliteration: 'tgt',
      wordChoices: [
        WordChoice(
          word: 'hi',
          definition: 'greeting',
          examplesSource: ['hi there'],
          examplesTarget: ['salut'],
        ),
      ],
      sourceSynonyms: ['hello'],
      targetSynonyms: ['salut'],
      elapsed: Duration(milliseconds: 5),
    );

    test('has value equality', () {
      expectValueEquality(result, result.copyWith(), [
        result.copyWith(text: 'Salut'),
        result.copyWith(isComplete: true),
        result.copyWith(detectedSource: 'de'),
        result.copyWith(elapsed: const Duration(seconds: 1)),
        const TranslationResult(engineId: 'ai:1', engineName: 'C', text: ''),
      ]);
    });

    test('copyWith keeps the other fields', () {
      final copy = result.copyWith(text: 'Salut', isComplete: true);
      expect(copy.text, 'Salut');
      expect(copy.isComplete, isTrue);
      expect(copy.wordChoices, result.wordChoices);
      expect(copy.sourceTransliteration, 'src');
      expect(copy.elapsed, result.elapsed);
      expect(result.toString(), contains('Bonjour'));
    });

    test('WordChoice has value equality', () {
      expectValueEquality(
        const WordChoice(word: 'a', examplesSource: ['x']),
        const WordChoice(word: 'a', examplesSource: ['x']),
        [
          const WordChoice(word: 'a'),
          const WordChoice(word: 'a', examplesTarget: ['x']),
        ],
      );
    });

    test('CompareEntry', () {
      const success = CompareEntry.success(result);
      expect(success.isSuccess, isTrue);
      expect(success.id, 'ai:1');
      expect(success.name, 'Claude');
      expectValueEquality(success, const CompareEntry.success(result), []);

      const failure = CompareEntry.failure(
        engineId: 'mozhi:deepl',
        engineName: 'DeepL',
        error: 'boom',
      );
      expect(failure.isSuccess, isFalse);
      expect(failure.id, 'mozhi:deepl');
      expect(failure.name, 'DeepL');
      expectValueEquality(
        failure,
        const CompareEntry.failure(
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          error: 'boom',
        ),
        [success],
      );
    });
  });

  group(Language, () {
    test('json round-trip', () {
      const language = Language(code: 'fr', name: 'French', nativeName: 'Fr');
      expect(Language.fromJson(language.toJson()), language);
      const custom = Language.custom('Pirate speak');
      final restored = Language.fromJson(custom.toJson());
      expect(restored.isCustom, isTrue);
      expect(restored.code, 'Pirate speak');
      expect(custom.toJson().containsKey('nativeName'), isFalse);
      expect(custom.toString(), 'Language(Pirate speak)');
    });

    test('auto', () {
      expect(Language.auto.isAuto, isTrue);
      expect(const Language(code: 'en', name: 'English').isAuto, isFalse);
      expect(
        const Language(code: 'en', name: 'English').hashCode,
        const Language(code: 'en', name: 'Anglais').hashCode,
      );
    });
  });

  group(MozhiInstance, () {
    test('displayName and json', () {
      const labelled = MozhiInstance(url: 'https://a.example', label: 'A');
      expect(labelled.displayName, 'A');
      const plain = MozhiInstance(url: 'https://b.example/');
      expect(plain.displayName, 'b.example');
      expect(MozhiInstance.fromJson(labelled.toJson()), labelled);
      expect(MozhiInstance.fromJson(plain.toJson()).isCustom, isTrue);
      expect(labelled.hashCode, labelled.url.hashCode);
      expect(MozhiInstance.publicInstances, isNotEmpty);
      expect(MozhiInstance.publicInstances.every((i) => !i.isCustom), isTrue);
    });
  });

  group(TranslationEngine, () {
    test('mozhi factory and capabilities', () {
      final google = TranslationEngine.mozhi('google', 'Google');
      expect(google.id, 'mozhi:google');
      expect(google.isMozhi, isTrue);
      expect(google.isAi, isFalse);
      expect(google.supportsTts, isTrue);
      expect(google.supportsOptions, isFalse);
      expect(google.supportsCustomLanguages, isFalse);
      expect(TranslationEngine.mozhi('deepl', 'DeepL').supportsTts, isFalse);
      expect(google.toString(), 'TranslationEngine(mozhi:google)');
      expect(google, TranslationEngine.mozhi('google', 'Google'));
      expect(
        google.hashCode,
        TranslationEngine.mozhi('google', 'Google').hashCode,
      );

      const ai = TranslationEngine(
        id: 'ai:x',
        kind: EngineKind.ai,
        name: 'X',
        providerId: 'x',
      );
      expect(ai.supportsOptions, isTrue);
      expect(ai.supportsCustomLanguages, isTrue);
      expect(ai.supportsTts, isTrue);
    });
  });

  group(TranslationRequest, () {
    test('copyWith and equality', () {
      const request = TranslationRequest(
        text: 'Hello',
        source: Language.auto,
        target: Language(code: 'fr', name: 'French'),
      );
      expect(request.copyWith(), request);
      expect(request.copyWith().hashCode, request.hashCode);
      expect(request.copyWith(text: 'Bye'), isNot(request));
      expect(
        request.copyWith(
          options: const TranslationOptions(formality: Formality.more),
        ),
        isNot(request),
      );
      expect(
        request.copyWith(
          source: const Language(code: 'en', name: 'English'),
          target: const Language(code: 'de', name: 'German'),
        ),
        isNot(request),
      );
    });
  });
}
