import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

void main() {
  group(MozhiWordChoice, () {
    group('fromJson', () {
      test('reads every field', () {
        final choice = MozhiWordChoice.fromJson(const {
          'word': 'maison',
          'definition': 'bâtiment servant de logement',
          'example': 'une maison de campagne',
          'examples_source': ['La maison est à vendre.'],
          'examples_target': ['The house is for sale.'],
        });

        expect(choice.word, 'maison');
        expect(choice.definition, 'bâtiment servant de logement');
        expect(choice.example, 'une maison de campagne');
        expect(choice.examplesSource, ['La maison est à vendre.']);
        expect(choice.examplesTarget, ['The house is for sale.']);
      });

      test('maps nulls, missing and mistyped fields to empty values', () {
        final choice = MozhiWordChoice.fromJson(const {
          'word': null,
          'definition': 3,
          'examples_source': null,
          'examples_target': 'The house is for sale.',
        });

        expect(choice.word, isEmpty);
        expect(choice.definition, isEmpty);
        expect(choice.example, isEmpty);
        expect(choice.examplesSource, isEmpty);
        expect(choice.examplesTarget, isEmpty);
      });
    });

    test('toJson is the inverse of fromJson', () {
      const json = {
        'word': 'house',
        'definition': '',
        'example': 'a big house',
        'examples_source': ['Une grande maison.'],
        'examples_target': ['A big house.'],
      };

      expect(MozhiWordChoice.fromJson(json).toJson(), json);
    });

    test('compares word, definition and example', () {
      const choice = MozhiWordChoice(word: 'cat', definition: 'a feline');

      expect(
        choice,
        const MozhiWordChoice(word: 'cat', definition: 'a feline'),
      );
      expect(
        choice.hashCode,
        const MozhiWordChoice(word: 'cat', definition: 'a feline').hashCode,
      );
      expect(choice, isNot(const MozhiWordChoice(word: 'cat')));
      expect(
        choice,
        isNot(
          const MozhiWordChoice(
            word: 'cat',
            definition: 'a feline',
            example: 'the cat purred',
          ),
        ),
      );
    });
  });
}
