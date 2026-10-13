import 'package:test/test.dart';
import 'package:translation_repository/src/prompts/prompt_sanitizer.dart';

const String zwsp = PromptSanitizer.zeroWidthSpace;

void main() {
  group('PromptSanitizer.neutraliseTag', () {
    test('defuses every opening and closing form of the tag', () {
      const forms = [
        '<source>',
        '</source>',
        '</SOURCE>',
        '< /source >',
        '<  source>',
        '</ Source\n>',
        '<source lang="x">',
        '<source/>',
        '</source',
      ];
      for (final form in forms) {
        final out = PromptSanitizer.neutraliseTag('a $form b', 'source');
        expect(out, 'a <$zwsp${form.substring(1)} b', reason: form);
      }
    });

    test('leaves other tags and text alone', () {
      const text = '<sources> <source-map> <sourcex> <b> a < b </s>';
      expect(PromptSanitizer.neutraliseTag(text, 'source'), text);
    });

    test('is idempotent and escapes the name', () {
      final once = PromptSanitizer.neutraliseTag('</source>', 'source');
      expect(PromptSanitizer.neutraliseTag(once, 'source'), once);
      expect(
        PromptSanitizer.neutraliseTag('<a.b> <axb>', 'a.b'),
        '<${zwsp}a.b> <axb>',
      );
    });
  });

  group('PromptSanitizer.restoreTags', () {
    test('removes the zero-width space after <', () {
      expect(
        PromptSanitizer.restoreTags('<${zwsp}source> x$zwsp'),
        '<source> x$zwsp',
      );
      expect(PromptSanitizer.restoreTags('plain'), 'plain');
    });

    test('keeps text whose original already had it', () {
      expect(
        PromptSanitizer.restoreTags('<${zwsp}x>', original: '<${zwsp}y>'),
        '<${zwsp}x>',
      );
    });
  });

  group('PromptSanitizer.singleLine', () {
    test('collapses whitespace and control characters', () {
      expect(
        PromptSanitizer.singleLine(' a\n\tb\r\nc\u0000d\u2028e\u0085f '),
        'a b c d e f',
      );
    });

    test('removes invisible format characters but keeps ZWJ/ZWNJ', () {
      expect(
        PromptSanitizer.singleLine('a\u200Bb\u202Ec\u2066d\uFEFFe'),
        'abcde',
      );
      expect(PromptSanitizer.singleLine('می\u200Cخواهم'), 'می\u200Cخواهم');
      expect(PromptSanitizer.singleLine('👩\u200D💻'), '👩\u200D💻');
    });

    test('optionally strips quotes and angle brackets', () {
      const text = '"a" `b` <c> «d» “e” it\'s ’f’';
      expect(PromptSanitizer.singleLine(text), text);
      expect(
        PromptSanitizer.singleLine(text, stripQuotes: true),
        "a b <c> d e it's ’f’",
      );
      expect(
        PromptSanitizer.singleLine(text, stripAngleBrackets: true),
        '"a" `b` c «d» “e” it\'s ’f’',
      );
    });

    test('caps the length', () {
      expect(PromptSanitizer.singleLine('abcdef', maxLength: 3), 'abc');
      expect(PromptSanitizer.singleLine('ab cdef', maxLength: 3), 'ab');
      expect(PromptSanitizer.singleLine('abc', maxLength: 3), 'abc');
      expect(
        PromptSanitizer.singleLine(
          'aaaa bbbb cccc',
          maxLength: 12,
          atWordBoundary: true,
        ),
        'aaaa bbbb',
      );
      // The word boundary is ignored when it would drop too much.
      expect(
        PromptSanitizer.singleLine(
          'a bbbbbbbbbbbb',
          maxLength: 8,
          atWordBoundary: true,
        ),
        'a bbbbbb',
      );
    });
  });

  group('PromptSanitizer.cap', () {
    test('never splits a surrogate pair', () {
      expect(PromptSanitizer.cap('😀😀😀', 2), '😀😀');
      expect(PromptSanitizer.cap('😀😀', 2), '😀😀');
    });
  });
}
