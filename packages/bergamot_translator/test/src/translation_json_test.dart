import 'dart:convert';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bergamot_translator/src/engine/translation_json.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('parseBergamotTranslations', () {
    test('reads texts without details', () {
      expect(
        parseBergamotTranslations(
          '[{"text":"Hallo Welt."},{"text":""}]',
          count: 2,
        ),
        const [
          OfflineTranslation(text: 'Hallo Welt.'),
          OfflineTranslation(text: ''),
        ],
      );
      expect(parseBergamotTranslations('[]', count: 0), isEmpty);
    });

    test('reads sentences, words, alignment and scores', () {
      final [result] = parseBergamotTranslations(
        jsonEncode([
          {
            'text': 'Hallo Welt.',
            'sentences': [
              {
                'source': [0, 12],
                'target': [0, 11],
                'score': -0.06,
                'words': [
                  {
                    'target': [0, 5],
                    'score': -0.007,
                    'source': [0, 5],
                    'p': 0.98,
                  },
                  {
                    'target': [6, 11],
                    'score': null,
                  },
                ],
              },
            ],
          },
        ]),
        count: 1,
      );

      expect(
        result,
        const OfflineTranslation(
          text: 'Hallo Welt.',
          sentences: [
            OfflineSentence(
              sourceStart: 0,
              sourceEnd: 12,
              targetStart: 0,
              targetEnd: 11,
              score: -0.06,
              words: [
                OfflineWord(
                  targetStart: 0,
                  targetEnd: 5,
                  sourceStart: 0,
                  sourceEnd: 5,
                  alignment: 0.98,
                  score: -0.007,
                ),
                OfflineWord(targetStart: 6, targetEnd: 11),
              ],
            ),
          ],
        ),
      );
    });

    test('accepts sentences without words or scores, and integer scores', () {
      final [result] = parseBergamotTranslations(
        '[{"text":"x","sentences":[{"source":[0,1],"target":[0,1],'
        '"score":0}]}]',
        count: 1,
      );

      expect(result.sentences.single.score, 0.0);
      expect(result.sentences.single.words, isEmpty);
    });

    test('rejects what the library does not write', () {
      Matcher invalid(String message) => throwsA(
        isA<BergamotEngineException>().having(
          (e) => e.message,
          'message',
          contains(message),
        ),
      );

      for (final (json, message) in [
        ('not json', 'Invalid engine output'),
        ('{}', 'no results, expected 1'),
        ('[]', '0 results, expected 1'),
        ('[1]', 'bad result'),
        ('[{"text":1}]', 'bad result'),
        ('[{"text":"","sentences":{}}]', 'bad sentences'),
        ('[{"text":"","sentences":[1]}]', 'bad sentence'),
        (
          '[{"text":"","sentences":[{"source":[0],"target":[0,1]}]}]',
          'bad source',
        ),
        (
          '[{"text":"","sentences":[{"source":[2,1],"target":[0,1]}]}]',
          'bad source',
        ),
        (
          '[{"text":"","sentences":[{"source":[0,1],"target":[-1,1]}]}]',
          'bad target',
        ),
        (
          '[{"text":"","sentences":[{"source":[0,1],"target":[0,1],'
              '"score":"x"}]}]',
          'bad score',
        ),
        (
          '[{"text":"","sentences":[{"source":[0,1],"target":[0,1],'
              '"words":{}}]}]',
          'bad words',
        ),
        (
          '[{"text":"","sentences":[{"source":[0,1],"target":[0,1],'
              '"words":[1]}]}]',
          'bad word',
        ),
        (
          '[{"text":"","sentences":[{"source":[0,1],"target":[0,1],'
              '"words":[{"target":[0,1],"source":"x"}]}]}]',
          'bad source',
        ),
        (
          '[{"text":"","sentences":[{"source":[0,1],"target":[0,1],'
              '"words":[{"target":[0,1],"p":true}]}]}]',
          'bad p',
        ),
      ]) {
        expect(
          () => parseBergamotTranslations(json, count: 1),
          invalid(message),
          reason: json,
        );
      }
    });
  });
}
