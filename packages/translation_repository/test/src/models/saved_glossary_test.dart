import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('mergeSavedGlossary', () {
    const empty = (terms: <String, String>{}, caseSensitive: <String>{});

    test('keeps the options when nothing is saved', () {
      const options = TranslationOptions(glossary: {'a': 'b'});
      expect(mergeSavedGlossary(options, empty), same(options));
    });

    test('adds the saved terms, trimmed, skipping blank ones', () {
      final merged = mergeSavedGlossary(const TranslationOptions(), (
        terms: const {' Haus ': ' building ', '': 'x', 'leer': ' '},
        caseSensitive: const {},
      ));
      expect(merged.glossary, {'Haus': 'building'});
      expect(merged.caseSensitiveGlossaryTerms, isEmpty);
    });

    test("the request's own term wins, compared without case", () {
      final merged = mergeSavedGlossary(
        const TranslationOptions(glossary: {'Haus': 'building'}),
        (
          terms: const {'haus': 'house', 'Tür': 'door'},
          caseSensitive: const {},
        ),
      );
      expect(merged.glossary, {'Tür': 'door', 'Haus': 'building'});
    });

    test('case-sensitive saved terms only give way to the same case', () {
      final merged = mergeSavedGlossary(
        const TranslationOptions(
          glossary: {'it': 'es'},
          caseSensitiveGlossaryTerms: {'it'},
        ),
        (
          terms: const {'IT': 'TI', 'it': 'ello'},
          caseSensitive: const {'IT', 'it'},
        ),
      );
      expect(merged.glossary, {'IT': 'TI', 'it': 'es'});
      expect(merged.caseSensitiveGlossaryTerms, {'it', 'IT'});
    });

    test('nothing taken keeps the options', () {
      const options = TranslationOptions(glossary: {'Haus': 'building'});
      expect(
        mergeSavedGlossary(options, (
          terms: const {'HAUS': 'house'},
          caseSensitive: const {},
        )),
        same(options),
      );
    });
  });
}
