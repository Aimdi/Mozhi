import 'dart:convert';

import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('ResponseParsers.parseProofread', () {
    test('joins a summary split into sentences with spaces', () {
      final result = ResponseParsers.parseProofread(
        jsonEncode({
          'corrected': 'Fine.',
          'summary': ['Clear and friendly.', '  ', 'No repetition.'],
          'edits': <Object>[],
        }),
        input: 'Fine.',
      );
      expect(result.summary, 'Clear and friendly. No repetition.');
    });

    test('separates summary fragments without final punctuation', () {
      String summary(List<String> items) => ResponseParsers.parseProofread(
        jsonEncode({'corrected': 'Fine.', 'summary': items}),
        input: 'Fine.',
      ).summary;

      expect(
        summary(['Formal tone', "Some repetition of 'very'"]),
        "Formal tone; Some repetition of 'very'",
      );
      // Each boundary follows the item before it.
      expect(
        summary(['Clear.', 'Formal tone', 'Little repetition']),
        'Clear. Formal tone; Little repetition',
      );
      expect(
        summary(['He said "fine."', '(Mostly formal.)', 'Short']),
        'He said "fine." (Mostly formal.) Short',
      );
      // No space after a full-width terminator; a fragment still gets one.
      expect(summary(['语气正式。', '有些重复']), '语气正式。有些重复');
      expect(summary(['语气正式', '有些重复']), '语气正式; 有些重复');
      expect(
        summary(['Was it clear?', 'Yes!', 'Done']),
        'Was it clear? Yes! Done',
      );
    });

    test('reads the summary from alternative keys', () {
      final result = ResponseParsers.parseProofread(
        '{"corrected": "Fine.", "feedback": "  Concise.  ", "edits": []}',
        input: 'Fine.',
      );
      expect(result.summary, 'Concise.');
    });

    test('a missing summary is empty', () {
      final result = ResponseParsers.parseProofread(
        '{"corrected": "Fine.", "edits": []}',
        input: 'Fine.',
      );
      expect(result.summary, isEmpty);
    });

    test('a regional language tag maps to its catalogue language', () {
      for (final code in ['en-GB', 'en_US', 'pt-BR', 'de-CH']) {
        final result = ResponseParsers.parseProofread(
          '{"language": "$code", "corrected": "x", "edits": []}',
          input: 'x',
        );
        expect(
          result.detectedLanguage,
          LanguageMatcher.normalize(code.replaceAll('_', '-')),
          reason: code,
        );
        expect(result.detectedLanguage, isNotEmpty, reason: code);
      }
    });

    test('keeps regional spelling and reading-level edits', () {
      const input =
          'The color of the center was utilized to facilitate comprehension.';
      final result = ResponseParsers.parseProofread(
        jsonEncode({
          'language': 'en',
          'corrected':
              'The colour of the centre was used to make it easier to '
              'understand.',
          'summary': 'Converted to British spelling and simplified.',
          'edits': [
            {
              'original': 'color',
              'replacement': 'colour',
              'explanation': 'British spelling.',
              'category': 'spelling',
            },
            {
              'original': 'center',
              'replacement': 'centre',
              'explanation': 'British spelling.',
              'category': 'spelling',
            },
            {
              'original': 'was utilized to facilitate comprehension',
              'replacement': 'was used to make it easier to understand',
              'explanation': 'Simpler words for B1 readers.',
              'category': 'readability',
            },
          ],
        }),
        input: input,
      );
      expect(result.edits.map((e) => e.category), [
        'spelling',
        'spelling',
        'clarity',
      ]);
      expect(
        result.edits.last.original,
        'was utilized to facilitate comprehension',
      );
      expect(result.detectedLanguage, 'en');
    });
  });
}
