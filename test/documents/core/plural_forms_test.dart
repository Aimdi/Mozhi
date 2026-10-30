// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/android_strings_parser.dart';
import 'package:mozhi/documents/core/parsers/locale_rules.dart';
import 'package:mozhi/documents/core/parsers/po_parser.dart';

import '../helpers/document_helpers.dart';

const _po = r'''
# Catalogue of the files screen.
msgid ""
msgstr ""
"Project-Id-Version: files 1.0\n"
"Language: \n"
"Content-Type: text/plain; charset=UTF-8\n"
"Plural-Forms: nplurals=INTEGER; plural=EXPRESSION;\n"

#. A count
#: src/files.c:5
#, c-format
msgctxt "list"
msgid "%d file"
msgid_plural "%d files"
msgstr[0] ""
msgstr[1] ""

#, c-format
msgid "One file"
msgid_plural "%d files left"
msgstr[0] ""
msgstr[1] ""

#~ msgid "Old"
#~ msgstr "Viejo"
''';

/// The translations of the four segments of [_po].
const _translations = ['[one] ⟨1⟩', '[other] ⟨1⟩', '[one word]', '[left] ⟨1⟩'];

/// The `msgstr` lines written for an entry: `one` and `other` stand for
/// the singular and plural translations of the first entry, `word` and
/// `left` for those of the second.
String _forms(List<String> forms) => [
  for (final (i, form) in forms.indexed)
    'msgstr[$i] "${switch (form) {
      'one' => '[one] %d',
      'other' => '[other] %d',
      'word' => '[one word]',
      _ => '[left] %d',
    }}"',
].join('\n');

const _android = '''
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:tools="http://schemas.android.com/tools">
    <plurals name="files">
        <!-- Number of files -->
        <item quantity="one">%d file</item>
        <!-- Everything else -->
        <item quantity="other" tools:ignore="Typos">%d files</item>
    </plurals>
    <string name="title">Files</string>
</resources>
''';

/// [_android] with the `files` plurals' items for [quantities].
String _androidWith(List<String> quantities) {
  final items = [
    for (final quantity in quantities)
      if (quantity == 'one')
        '<item quantity="one">[one] %d</item>'
      else
        '<item quantity="$quantity" tools:ignore="Typos">[other] %d</item>',
  ].join('\n        ');
  return _android
      .replaceFirst(
        RegExp('<item quantity="one">.*</item>', dotAll: true),
        '<!-- Everything else -->\n        $items',
      )
      .replaceFirst('>Files<', '>Fichiers<');
}

void main() {
  group('PO plural forms', () {
    final cases = {
      'en': (
        'nplurals=2; plural=(n != 1);',
        ['one', 'other'],
        ['word', 'left'],
      ),
      // Form 0 is 0 and 1: "One file" would be wrong for 0.
      'fr': ('nplurals=2; plural=(n > 1);', ['one', 'other'], ['left', 'left']),
      // Form 0 is 1, 21, 31, ...
      'ru': (
        'nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && '
            'n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);',
        ['one', 'other', 'other'],
        ['left', 'left', 'left'],
      ),
      'pl': (
        'nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && '
            '(n%100<10 || n%100>=20) ? 1 : 2);',
        ['one', 'other', 'other'],
        ['word', 'left', 'left'],
      ),
      // Form 1 is the singular; 0 has a form of its own.
      'ar': (
        'nplurals=6; plural=(n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : '
            'n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5);',
        ['other', 'one', 'other', 'other', 'other', 'other'],
        ['left', 'word', 'left', 'left', 'left', 'left'],
      ),
      'ja': ('nplurals=1; plural=0;', ['other'], ['left']),
    };
    for (final MapEntry(key: language, value: (rule, files, left))
        in cases.entries) {
      test('writes the forms of $language', () {
        final document = parsePo(_po, targetLanguage: language);
        expectRoundTrip(document, _po);
        expect(texts(document), [
          '⟨1⟩ file',
          '⟨1⟩ files',
          'One file',
          '⟨1⟩ files left',
        ]);
        final output = document.render(_translations);
        expect(output, contains('"Plural-Forms: $rule\\n"'));
        expect(output, contains('"Language: $language\\n"'));
        expect(
          output,
          contains(
            '#. A count\n#: src/files.c:5\n#, c-format\nmsgctxt "list"\n'
            'msgid "%d file"\nmsgid_plural "%d files"\n${_forms(files)}\n\n',
          ),
        );
        expect(
          output,
          contains(
            'msgid "One file"\nmsgid_plural "%d files left"\n'
            '${_forms(left)}\n\n',
          ),
        );
        expect(output, endsWith('#~ msgid "Old"\n#~ msgstr "Viejo"\n'));
        expect(PluralForms.parse(rule)!.count, files.length);
      });
    }

    const english =
        'msgid ""\n'
        'msgstr ""\n'
        '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"\n'
        '\n'
        'msgid "%d day"\n'
        'msgid_plural "%d days"\n'
        'msgstr[0] ""\n'
        'msgstr[1] ""\n';

    test('takes the target rule when no language is named yet', () {
      final output = parsePo(
        english,
        targetLanguage: 'ru',
      ).render(['⟨1⟩ день', '⟨1⟩ дней']);
      expect(output, contains('nplurals=3;'));
      expect(output, contains('msgstr[2] "%d дней"'));
    });

    test('keeps the header rule of translated plurals', () {
      final translated = english.replaceFirst(
        'msgstr[0] ""\nmsgstr[1] ""',
        'msgstr[0] "%d Tag"\nmsgstr[1] "%d Tage"',
      );
      final withMore =
          '$translated\nmsgid "%d week"\nmsgid_plural "%d weeks"\n'
          'msgstr[0] ""\nmsgstr[1] ""\n';
      final output = parsePo(
        withMore,
        targetLanguage: 'ru',
      ).render(['⟨1⟩ неделя', '⟨1⟩ недель']);
      expect(output, contains('nplurals=2; plural=(n != 1);'));
      expect(
        output,
        contains('msgstr[0] "%d неделя"\nmsgstr[1] "%d недель"\n'),
      );

      // Same language: its own rule stays, whatever it is.
      final german = english.replaceFirst(
        '"Plural-Forms',
        '"Language: de\\n"\n"Plural-Forms',
      );
      final kept = parsePo(german, targetLanguage: 'de').render(['a', 'b']);
      expect(kept, contains('nplurals=2; plural=(n != 1);'));
    });

    test('gives languages it does not know two forms', () {
      final output = parsePo(_po, targetLanguage: 'haw').render(_translations);
      expect(
        output,
        contains(r'"Plural-Forms: nplurals=2; plural=(n != 1);\n"'),
      );
      expect(output, contains(_forms(['one', 'other'])));
      expect(defaultGettextPluralForms, 'nplurals=2; plural=(n != 1);');
    });

    test('isOnlyOne tells singular forms apart', () {
      final english = PluralForms.parse(gettextPluralForms('en'))!;
      final russian = PluralForms.parse(gettextPluralForms('ru'))!;
      final arabic = PluralForms.parse(gettextPluralForms('ar'))!;
      expect(english.isOnlyOne(0), isTrue);
      expect(english.isOnlyOne(1), isFalse);
      expect(russian.isOnlyOne(0), isFalse);
      expect(arabic.isOnlyOne(1), isTrue);
      expect(arabic.isOnlyOne(0), isFalse);
    });
  });

  group('Android plurals', () {
    final cases = {
      'en': ['one', 'other'],
      'fr': ['one', 'many', 'other'],
      'ru': ['one', 'few', 'many', 'other'],
      'pl': ['one', 'few', 'many', 'other'],
      'ar': ['zero', 'one', 'two', 'few', 'many', 'other'],
      'ja': ['other'],
    };
    for (final MapEntry(key: language, value: quantities) in cases.entries) {
      test('get the quantities of $language', () {
        final document = parseAndroidStrings(
          _android,
          targetLanguage: language,
        );
        expectRoundTrip(document, _android);
        expect(texts(document), ['⟨1⟩ file', '⟨1⟩ files', 'Files']);
        final output = document.render([
          '[one] ⟨1⟩',
          '[other] ⟨1⟩',
          'Fichiers',
        ]);
        if (language == 'en') {
          // The quantities match: the items stay where they are.
          expect(
            output,
            _android
                .replaceFirst('%d file<', '[one] %d<')
                .replaceFirst('%d files<', '[other] %d<')
                .replaceFirst('>Files<', '>Fichiers<'),
          );
        } else {
          expect(output, _androidWith(quantities));
        }
        expect(pluralCategories(language), quantities);
      });
    }

    test('keep the source quantities without a known target', () {
      for (final target in [null, 'Pirate speak', 'xx']) {
        final output = parseAndroidStrings(
          _android,
          targetLanguage: target,
        ).render(['a ⟨1⟩', 'b ⟨1⟩', 'c']);
        expect(output, contains('<item quantity="one">a %d</item>'));
        expect(output, isNot(contains('quantity="few"')));
      }
    });

    test('fall back to other, keep unusual plurals as they are', () {
      const onlyOther =
          '<resources><plurals name="n"><item quantity="other">%d items'
          '</item></plurals><plurals name="odd"><item quantity="one">One'
          '</item><string name="x">No</string></plurals></resources>';
      final document = parseDocument(
        onlyOther,
        DocumentFormat.androidStrings,
        targetLanguage: 'ru',
      );
      expectRoundTrip(document, onlyOther);
      final output = document.render(['⟨1⟩ штук', 'Один']);
      expect(
        output,
        contains(
          '<plurals name="n"><item quantity="one">%d штук</item>'
          '<item quantity="few">%d штук</item><item quantity="many">%d штук'
          '</item><item quantity="other">%d штук</item></plurals>',
        ),
      );
      expect(
        output,
        contains(
          '<plurals name="odd"><item quantity="one">Один</item><string '
          'name="x">No</string></plurals>',
        ),
      );
    });
  });
}
