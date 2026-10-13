import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/presets/data/glossary_table.dart';
import 'package:mozhi/presets/models/glossary.dart';

void main() {
  group('GlossaryTable.parse', () {
    test('parses rows without a header', () {
      final result = GlossaryTable.parse('cat,Katze\ndog , Hund ,pet,yes\n');
      expect(result.skipped, 0);
      expect(result.terms, const [
        GlossaryTerm(source: 'cat', target: 'Katze'),
        GlossaryTerm(
          source: 'dog',
          target: 'Hund',
          note: 'pet',
          caseSensitive: true,
        ),
      ]);
    });

    test('recognises a header in any column order', () {
      final result = GlossaryTable.parse(
        'Translation;Note;Source Term;Match_Case\r\n'
        'Katze;animal;cat;x\r\n'
        'Hund;;dog;no\r\n',
      );
      expect(result.terms, const [
        GlossaryTerm(
          source: 'cat',
          target: 'Katze',
          note: 'animal',
          caseSensitive: true,
        ),
        GlossaryTerm(source: 'dog', target: 'Hund'),
      ]);
    });

    test('header without optional columns', () {
      final result = GlossaryTable.parse('term,translation\na,b\n');
      expect(result.terms, const [GlossaryTerm(source: 'a', target: 'b')]);
    });

    test('handles quoted fields with delimiters, quotes and newlines', () {
      final result = GlossaryTable.parse(
        'source,target,note\n'
        '"Hello, world","Hallo, Welt","say ""hi""\nwarmly"\n'
        '  "padded"  , "  keep spaces  " ,x\n',
      );
      expect(result.terms, const [
        GlossaryTerm(
          source: 'Hello, world',
          target: 'Hallo, Welt',
          note: 'say "hi"\nwarmly',
        ),
        GlossaryTerm(source: 'padded', target: 'keep spaces', note: 'x'),
      ]);
    });

    test('detects tabs and keeps commas inside TSV fields', () {
      final result = GlossaryTable.parse('a, b\tc, d\n"x"\t"y\tz"');
      expect(result.terms, const [
        GlossaryTerm(source: 'a, b', target: 'c, d'),
        GlossaryTerm(source: 'x', target: 'y\tz'),
      ]);
    });

    test('skips blank lines and counts incomplete rows', () {
      final result = GlossaryTable.parse(
        '﻿\n\ncat,Katze\n,\nonly source\n ,target\n\r\ndog,Hund',
      );
      expect(result.terms.map((t) => t.source), ['cat', 'dog']);
      expect(result.skipped, 2);
    });

    test('lenient with stray quotes', () {
      final result = GlossaryTable.parse(
        '5" screen,5-Zoll-Bildschirm\n"quoted"tail,x\n"open,never closed',
      );
      expect(result.terms, const [
        GlossaryTerm(source: '5" screen', target: '5-Zoll-Bildschirm'),
        GlossaryTerm(source: 'quotedtail', target: 'x'),
      ]);
      // The unterminated quote swallows the rest as a single field.
      expect(result.skipped, 1);
    });

    test('explicit delimiter', () {
      final result = GlossaryTable.parse('a|b', delimiter: '|');
      expect(result.terms, const [GlossaryTerm(source: 'a', target: 'b')]);
    });

    test('empty input', () {
      final result = GlossaryTable.parse('  \n ');
      expect(result.terms, isEmpty);
      expect(result.skipped, 0);
    });
  });

  group('GlossaryTable.detectDelimiter', () {
    test('picks tab, comma or semicolon', () {
      expect(GlossaryTable.detectDelimiter('a\tb'), '\t');
      expect(GlossaryTable.detectDelimiter('a,b'), ',');
      expect(GlossaryTable.detectDelimiter('a;b;c'), ';');
      expect(GlossaryTable.detectDelimiter('a;b,c'), ',');
      expect(GlossaryTable.detectDelimiter('"x;y;z",a'), ',');
      expect(GlossaryTable.detectDelimiter('\n\na;b\nc,d,e,f'), ';');
      expect(GlossaryTable.detectDelimiter('single'), ',');
    });
  });

  group('GlossaryTable.format', () {
    const terms = [
      GlossaryTerm(source: 'cat', target: 'Katze'),
      GlossaryTerm(
        source: 'Hello, "you"',
        target: ' padded ',
        note: 'two\nlines',
        caseSensitive: true,
      ),
    ];

    test('writes CSV with header and quoting', () {
      expect(
        GlossaryTable.format(terms),
        'source,target,note,case_sensitive\n'
        'cat,Katze,,false\n'
        '"Hello, ""you"""," padded ","two\nlines",true\n',
      );
    });

    test('writes TSV without header', () {
      expect(
        GlossaryTable.format(
          const [GlossaryTerm(source: 'a,b', target: 'c\td')],
          format: GlossaryTableFormat.tsv,
          header: false,
        ),
        'a,b\t"c\td"\t\tfalse\n',
      );
    });

    test('empty without header', () {
      expect(GlossaryTable.format(const [], header: false), isEmpty);
    });

    test('round-trips through parse', () {
      for (final format in GlossaryTableFormat.values) {
        final text = GlossaryTable.format(terms, format: format);
        final parsed = GlossaryTable.parse(text);
        expect(parsed.terms, [
          terms.first,
          // Unquoted output is trimmed on parse; quoted fields are kept.
          terms.last,
        ], reason: format.name);
      }
    });

    test('formats expose mime types and extensions', () {
      expect(GlossaryTableFormat.csv.extension, 'csv');
      expect(GlossaryTableFormat.tsv.mimeType, 'text/tab-separated-values');
    });
  });
}
