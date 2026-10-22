import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group(TranslationOptions, () {
    const custom = TranslationOptions(
      style: TranslationStyle.literal,
      formality: Formality.preferMore,
      readingLevel: ReadingLevel.b1,
      speakerGender: Gender.feminine,
      addresseeGender: Gender.neutral,
      context: 'Text message to my landlord',
      preserveFormatting: false,
      glossary: {'server': 'serveur', 'cloud': 'nuage'},
      instructions: 'Make it shorter.',
      formalityContext: 'My boss, but we are on first-name terms',
      caseSensitiveGlossaryTerms: {'cloud'},
    );

    test('defaults', () {
      const options = TranslationOptions();
      expect(options.style, TranslationStyle.natural);
      expect(options.formality, Formality.automatic);
      expect(options.readingLevel, ReadingLevel.standard);
      expect(options.speakerGender, Gender.unknown);
      expect(options.addresseeGender, Gender.unknown);
      expect(options.context, isEmpty);
      expect(options.preserveFormatting, isTrue);
      expect(options.glossary, isEmpty);
      expect(options.instructions, isEmpty);
      expect(options.formalityContext, isEmpty);
      expect(options.caseSensitiveGlossaryTerms, isEmpty);
      expect(options.isDefault, isTrue);
    });

    test('isDefault is false when anything differs', () {
      expect(custom.isDefault, isFalse);
      expect(const TranslationOptions(glossary: {'a': 'b'}).isDefault, isFalse);
      expect(const TranslationOptions(context: 'x').isDefault, isFalse);
      expect(
        const TranslationOptions(formalityContext: 'x').isDefault,
        isFalse,
      );
    });

    group('equality', () {
      test('is deep for the glossary', () {
        const a = TranslationOptions(glossary: {'a': 'b', 'c': 'd'});
        const b = TranslationOptions(glossary: {'c': 'd', 'a': 'b'});
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
        expect(
          a,
          isNot(const TranslationOptions(glossary: {'a': 'x', 'c': 'd'})),
        );
      });

      test('compares every field', () {
        final variants = [
          custom.copyWith(style: TranslationStyle.natural),
          custom.copyWith(formality: Formality.more),
          custom.copyWith(readingLevel: ReadingLevel.c2),
          custom.copyWith(speakerGender: Gender.masculine),
          custom.copyWith(addresseeGender: Gender.feminine),
          custom.copyWith(context: 'other'),
          custom.copyWith(preserveFormatting: true),
          custom.copyWith(glossary: const {}),
          custom.copyWith(instructions: ''),
          custom.copyWith(formalityContext: ''),
          custom.copyWith(caseSensitiveGlossaryTerms: const {}),
        ];
        for (final variant in variants) {
          expect(variant, isNot(equals(custom)));
        }
        expect(custom.copyWith(), equals(custom));
        expect(custom.copyWith().hashCode, custom.hashCode);
        expect(
          custom.copyWith(formalityContext: 'other').hashCode,
          isNot(custom.hashCode),
        );
        expect(
          custom.copyWith(caseSensitiveGlossaryTerms: {'cloud'}),
          equals(custom),
        );
        expect(
          custom.copyWith(caseSensitiveGlossaryTerms: {'cloud'}).hashCode,
          custom.hashCode,
        );
        expect(custom, isNot(equals('not options')));
      });

      test('identical instances are equal', () {
        expect(custom == custom, isTrue);
      });
    });

    test('copyWith replaces only given fields', () {
      final copy = const TranslationOptions().copyWith(
        formality: Formality.less,
        glossary: {'x': 'y'},
      );
      expect(copy.formality, Formality.less);
      expect(copy.glossary, {'x': 'y'});
      expect(copy.style, TranslationStyle.natural);
      expect(copy.preserveFormatting, isTrue);
    });

    group('json', () {
      test('round-trips', () {
        expect(TranslationOptions.fromJson(custom.toJson()), equals(custom));
        expect(
          TranslationOptions.fromJson(const TranslationOptions().toJson()),
          equals(const TranslationOptions()),
        );
      });

      test('serialises enums by name', () {
        final json = custom.toJson();
        expect(json['style'], 'literal');
        expect(json['formality'], 'preferMore');
        expect(json['readingLevel'], 'b1');
        expect(json['speakerGender'], 'feminine');
        expect(json['addresseeGender'], 'neutral');
        expect(json['glossary'], {'server': 'serveur', 'cloud': 'nuage'});
        expect(json['preserveFormatting'], isFalse);
      });

      test('omits empty instructions', () {
        expect(
          const TranslationOptions().toJson().containsKey('instructions'),
          isFalse,
        );
        expect(custom.toJson()['instructions'], 'Make it shorter.');
      });

      test('writes formalityContext only when non-empty', () {
        expect(
          const TranslationOptions().toJson().containsKey('formalityContext'),
          isFalse,
        );
        expect(
          custom.toJson()['formalityContext'],
          'My boss, but we are on first-name terms',
        );
      });

      test('reads formalityContext and Kagi formality_context', () {
        expect(
          TranslationOptions.fromJson(const {'formalityContext': 'tone'})
              .formalityContext,
          'tone',
        );
        expect(
          TranslationOptions.fromJson(const {'formality_context': 'kagi tone'})
              .formalityContext,
          'kagi tone',
        );
        expect(
          TranslationOptions.fromJson(const {'formalityContext': 3})
              .formalityContext,
          isEmpty,
        );
      });

      test('falls back to defaults for unknown or missing values', () {
        final options = TranslationOptions.fromJson(const {
          'style': 'baroque',
          'formality': 42,
          'readingLevel': 'z9',
          'speakerGender': null,
          'context': 7,
          'preserveFormatting': 'maybe',
          'glossary': 'nope',
        });
        expect(options, equals(const TranslationOptions()));
        expect(
          TranslationOptions.fromJson(const {}),
          equals(const TranslationOptions()),
        );
      });

      test("accepts Kagi's wire values", () {
        final options = TranslationOptions.fromJson(const {
          'translation_style': 'literal',
          'formality': 'prefer_less',
          'language_complexity': 'A2',
          'speaker_gender': 'male',
          'addressee_gender': 'female',
          'preserve_formatting': 'false',
        });
        expect(options.style, TranslationStyle.literal);
        expect(options.formality, Formality.preferLess);
        expect(options.readingLevel, ReadingLevel.a2);
        expect(options.speakerGender, Gender.masculine);
        expect(options.addresseeGender, Gender.feminine);
        expect(options.preserveFormatting, isFalse);
      });

      test('maps formality aliases', () {
        Formality parse(String value) =>
            TranslationOptions.fromJson({'formality': value}).formality;
        expect(parse('default'), Formality.automatic);
        expect(parse('formal'), Formality.more);
        expect(parse('informal'), Formality.less);
        expect(parse('PREFER-MORE'), Formality.preferMore);
        expect(parse('non-binary'), Formality.automatic);
      });

      test('maps gender aliases', () {
        Gender parse(String value) =>
            TranslationOptions.fromJson({'speakerGender': value}).speakerGender;
        expect(parse('woman'), Gender.feminine);
        expect(parse('man'), Gender.masculine);
        expect(parse('non-binary'), Gender.neutral);
        expect(parse('nonbinary'), Gender.neutral);
        expect(parse('?'), Gender.unknown);
      });

      test('writes caseSensitiveGlossaryTerms only when non-empty', () {
        expect(
          const TranslationOptions().toJson().containsKey(
            'caseSensitiveGlossaryTerms',
          ),
          isFalse,
        );
        expect(custom.toJson()['caseSensitiveGlossaryTerms'], ['cloud']);
        expect(
          TranslationOptions.fromJson(const {
            'caseSensitiveGlossaryTerms': ['IT', ' ', 3, 'Apple'],
          }).caseSensitiveGlossaryTerms,
          {'IT', 'Apple'},
        );
        expect(
          TranslationOptions.fromJson(const {
            'caseSensitiveGlossaryTerms': 'IT',
          }).caseSensitiveGlossaryTerms,
          isEmpty,
        );
      });

      test('parses tolerant glossaries', () {
        final fromMap = TranslationOptions.fromJson(const {
          'glossary': {'a': 'b', ' ': 'blank', 'n': 1, 2: 'x'},
        });
        expect(fromMap.glossary, {'a': 'b'});

        final fromList = TranslationOptions.fromJson(const {
          'glossary': [
            {'source': 'cat', 'target': 'chat'},
            {'source': '', 'target': 'empty'},
            {'source': 'dog'},
            'junk',
          ],
        });
        expect(fromList.glossary, {'cat': 'chat'});
      });

      test('reads booleans', () {
        expect(
          TranslationOptions.fromJson(const {'preserveFormatting': 'true'})
              .preserveFormatting,
          isTrue,
        );
        expect(
          TranslationOptions.fromJson(const {'preserveFormatting': false})
              .preserveFormatting,
          isFalse,
        );
      });
    });

    test('toString mentions the settings', () {
      expect(custom.toString(), contains('formality: preferMore'));
      expect(
        custom.toString(),
        contains('formalityContext: My boss, but we are on first-name terms'),
      );
      expect(
        custom.toString(),
        contains('caseSensitiveGlossaryTerms: {cloud}'),
      );
      expect(
        const TranslationOptions().toString(),
        isNot(contains('caseSensitiveGlossaryTerms')),
      );
    });
  });
}
