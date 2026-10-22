import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

import 'pack_helpers.dart';

void main() {
  group('DictionaryPackEntry', () {
    test('round-trips through its compact JSON', () {
      expect(DictionaryPackEntry.fromJson(houseNoun.toJson()), houseNoun);
      expect(houseNoun.toJson()['t'], {
        'de': [
          ['Haus', 0],
          ['Dynastie', 1],
        ],
        'zh': [
          ['房子', -1],
        ],
      });
      expect(cafe.toJson(), {
        'w': 'café',
        'p': 'noun',
        's': [
          {'g': 'A coffee shop.'},
        ],
      });
      expect(DictionaryPackEntry.fromJson(mice.toJson()), mice);
      expect(mice.toJson()['s'], [
        {'g': 'plural of mouse', 'o': 'mouse'},
      ]);
    });

    test('has value equality', () {
      expect(
        houseNoun.hashCode,
        DictionaryPackEntry.fromJson(houseNoun.toJson()).hashCode,
      );
      expect(houseNoun, isNot(houseVerb));
      expect('$houseNoun', 'DictionaryPackEntry(house, noun)');
      expect(houseNoun.senses.first, isNot(houseNoun.senses.last));
      expect(
        houseNoun.senses.first.hashCode,
        DictionaryPackSense.fromJson(houseNoun.senses.first.toJson()).hashCode,
      );
      expect(
        const DictionaryPackExample('a', 'b').hashCode,
        const DictionaryPackExample('a', 'b').hashCode,
      );
      expect(
        const DictionaryPackTranslation('a').hashCode,
        const DictionaryPackTranslation('a').hashCode,
      );
      expect(
        const DictionaryPackTranslation('a'),
        isNot(const DictionaryPackTranslation('a', 0)),
      );
    });

    test('examples have value equality', () {
      const example = DictionaryPackExample('El gato.', 'The cat.');
      expect(example, const DictionaryPackExample('El gato.', 'The cat.'));
      expect(example, isNot(const DictionaryPackExample('El gato.')));
      expect(example.toJson(), ['El gato.', 'The cat.']);
    });

    test('tells forms of other words', () {
      expect(mice.isFormOf, isTrue);
      expect(cafe.isFormOf, isFalse);
      expect(const DictionaryPackEntry(word: 'x').isFormOf, isFalse);
    });

    test('rejects malformed JSON', () {
      for (final json in <Object?>[
        'entry',
        <String, Object?>{},
        {'w': ''},
        {'w': 1},
        {'w': 'x', 's': 'senses'},
        {
          'w': 'x',
          's': ['sense'],
        },
        {
          'w': 'x',
          'y': [1],
        },
        {'w': 'x', 't': <Object?>[]},
        {
          'w': 'x',
          't': {'de': 'Haus'},
        },
        {
          'w': 'x',
          't': {
            'de': [
              ['Haus'],
            ],
          },
        },
        {
          'w': 'x',
          's': [
            {
              'g': 'g',
              'x': [<Object?>[]],
            },
          ],
        },
        {
          'w': 'x',
          's': [
            {
              'g': 'g',
              'x': ['a'],
            },
          ],
        },
        {
          'w': 'x',
          's': [
            {
              'g': 'g',
              'x': [
                ['a', 'b', 'c'],
              ],
            },
          ],
        },
        {
          'w': 'x',
          's': [
            {
              'g': 'g',
              'x': [
                ['a', 1],
              ],
            },
          ],
        },
      ]) {
        expect(
          () => DictionaryPackEntry.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });
  });
}
