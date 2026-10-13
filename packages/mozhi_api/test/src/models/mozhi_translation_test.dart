import 'dart:convert';

import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

import '../fixtures.dart';

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  group(MozhiTranslation, () {
    group('fromJson', () {
      test('parses a Google response with dictionary data', () {
        final translation = MozhiTranslation.fromJson(
          _decode(googleTranslationJson),
        );

        expect(translation.engine, 'google');
        expect(translation.translatedText, 'cat');
        expect(translation.detectedLanguage, 'ja');
        expect(translation.sourceLanguage, 'auto');
        expect(translation.targetLanguage, 'en');
        expect(translation.sourceTransliteration, 'Neko');
        expect(translation.targetTransliteration, isEmpty);
        expect(translation.wordChoices, const [
          MozhiWordChoice(
            word: 'cat',
            definition:
                'a small domesticated carnivorous mammal with soft fur, a '
                'short snout, and retractable claws.',
            example: 'the cat sat on the windowsill and purred',
          ),
          MozhiWordChoice(word: 'cat', definition: 'a jazz enthusiast.'),
        ]);
        expect(translation.wordChoices.first.examplesSource, isEmpty);
        expect(translation.sourceSynonyms, isEmpty);
        expect(translation.targetSynonyms, [
          'kitty',
          'puss',
          'pussycat',
          'feline',
          'moggy',
        ]);
        expect(translation.sourceAntonyms, isEmpty);
        expect(translation.targetAntonyms, isEmpty);
        expect(translation.sourceEquivalentTargetLang, {
          '猫': ['cat', 'puss'],
        });
        expect(translation.targetEquivalentSourceLang, {
          'cat': ['猫', 'ネコ', 'にゃんこ'],
        });
      });

      test('parses Reverso word choices with example pairs', () {
        final translation = MozhiTranslation.fromJson(
          _decode(reversoTranslationJson),
        );

        final [house, home] = translation.wordChoices;
        expect(house.word, 'house');
        expect(house.examplesSource, [
          'Il habite dans une grande maison.',
          'La maison est à vendre.',
        ]);
        expect(house.examplesTarget, [
          'He lives in a big house.',
          'The house is for sale.',
        ]);
        expect(home.word, 'home');
        expect(home.definition, isEmpty);
        expect(home.examplesTarget, ["I'm going home."]);
      });

      test('normalises Go nils and missing keys (DeepL) to empty values', () {
        final translation = MozhiTranslation.fromJson(
          _decode(deeplTranslationJson),
        );

        expect(translation.engine, 'deepl');
        expect(translation.translatedText, 'Good morning, how are you?');
        expect(translation.detectedLanguage, isEmpty);
        expect(translation.targetLanguage, 'en-US');
        expect(translation.wordChoices, isEmpty);
        expect(translation.sourceTransliteration, isEmpty);
        expect(translation.targetTransliteration, isEmpty);
        expect(translation.sourceSynonyms, isEmpty);
        expect(translation.targetSynonyms, isEmpty);
        expect(translation.sourceAntonyms, isEmpty);
        expect(translation.targetAntonyms, isEmpty);
        expect(translation.sourceEquivalentTargetLang, isEmpty);
        expect(translation.targetEquivalentSourceLang, isEmpty);
      });

      test('parses an empty object', () {
        final translation = MozhiTranslation.fromJson(const {});

        expect(translation.engine, isEmpty);
        expect(translation.translatedText, isEmpty);
        expect(
          translation.toJson(),
          const MozhiTranslation(engine: '', translatedText: '').toJson(),
        );
      });

      test('ignores values of the wrong type', () {
        final translation = MozhiTranslation.fromJson(
          _decode('''
{
  "engine": 7,
  "translated-text": ["Hello"],
  "detected": false,
  "word_choices": [{"word": "hi", "definition": 3}, "hi", null],
  "source_synonyms": "hello",
  "target_synonyms": ["hi", 2, null, "hey"],
  "source_equivalent_target_lang": ["word"],
  "target_equivalent_source_lang": {"hi": "salut", "hey": ["coucou", 1]}
}'''),
        );

        expect(translation.engine, isEmpty);
        expect(translation.translatedText, isEmpty);
        expect(translation.detectedLanguage, isEmpty);
        expect(translation.wordChoices, const [MozhiWordChoice(word: 'hi')]);
        expect(translation.sourceSynonyms, isEmpty);
        expect(translation.targetSynonyms, ['hi', 'hey']);
        expect(translation.sourceEquivalentTargetLang, isEmpty);
        expect(translation.targetEquivalentSourceLang, {
          'hi': <String>[],
          'hey': ['coucou'],
        });
      });

      test('returns unmodifiable collections', () {
        final translation = MozhiTranslation.fromJson(
          _decode(googleTranslationJson),
        );

        expect(
          () => translation.targetSynonyms.add('x'),
          throwsUnsupportedError,
        );
        expect(translation.wordChoices.clear, throwsUnsupportedError);
        expect(
          () => translation.sourceEquivalentTargetLang['x'] = [],
          throwsUnsupportedError,
        );
        expect(
          () => translation.sourceEquivalentTargetLang['猫']!.add('x'),
          throwsUnsupportedError,
        );
      });
    });

    group('toJson', () {
      test('uses the Mozhi key names', () {
        expect(
          const MozhiTranslation(
            engine: 'google',
            translatedText: 'Hello',
            detectedLanguage: 'fr',
            sourceLanguage: 'auto',
            targetLanguage: 'en',
            wordChoices: [MozhiWordChoice(word: 'hello', example: 'Hi!')],
            sourceTransliteration: 'bonzhur',
            targetTransliteration: 'heh-loh',
            sourceSynonyms: ['salut'],
            targetSynonyms: ['hi'],
            sourceAntonyms: ['adieu'],
            targetAntonyms: ['goodbye'],
            sourceEquivalentTargetLang: {
              'bonjour': ['hello'],
            },
            targetEquivalentSourceLang: {
              'hello': ['bonjour', 'salut'],
            },
          ).toJson(),
          {
            'engine': 'google',
            'detected': 'fr',
            'translated-text': 'Hello',
            'source_language': 'auto',
            'target_language': 'en',
            'word_choices': [
              {
                'word': 'hello',
                'definition': '',
                'example': 'Hi!',
                'examples_source': <String>[],
                'examples_target': <String>[],
              },
            ],
            'source_transliteration': 'bonzhur',
            'target_transliteration': 'heh-loh',
            'source_synonyms': ['salut'],
            'target_synonyms': ['hi'],
            'source_antonyms': ['adieu'],
            'target_antonyms': ['goodbye'],
            'source_equivalent_target_lang': {
              'bonjour': ['hello'],
            },
            'target_equivalent_source_lang': {
              'hello': ['bonjour', 'salut'],
            },
          },
        );
      });

      for (final (name, fixture) in [
        ('Google', googleTranslationJson),
        ('DeepL', deeplTranslationJson),
        ('Reverso', reversoTranslationJson),
      ]) {
        test('round-trips a $name response through JSON text', () {
          final original = MozhiTranslation.fromJson(_decode(fixture));
          final json = jsonEncode(original.toJson());
          final restored = MozhiTranslation.fromJson(_decode(json));

          expect(restored.toJson(), original.toJson());
          expect(
            restored.wordChoices.map((c) => c.examplesTarget),
            original.wordChoices.map((c) => c.examplesTarget),
          );
        });
      }
    });
  });
}
