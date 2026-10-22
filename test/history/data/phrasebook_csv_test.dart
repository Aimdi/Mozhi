import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/history/data/phrasebook_csv.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

HistoryEntry _entry(
  String text,
  String translation, {
  Language source = const Language(code: 'en', name: 'English'),
  Language target = const Language(code: 'fr', name: 'French'),
  String? detected,
  HistoryEntryKind kind = HistoryEntryKind.translation,
}) => HistoryEntry(
  id: text,
  text: text,
  translation: translation,
  source: source,
  target: target,
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime(2026, 3, 7, 23, 59),
  detectedSource: detected,
  isFavorite: true,
  kind: kind,
);

void main() {
  group(PhrasebookCsv, () {
    test('starts with the Anki header and one CRLF row per entry', () {
      final csv = PhrasebookCsv.encode([
        _entry('Good morning', 'Bonjour'),
        _entry(
          'gato',
          'noun · cat',
          source: const Language(code: 'es', name: 'Spanish'),
          target: const Language(code: 'en', name: 'English'),
          kind: HistoryEntryKind.dictionary,
        ),
      ]);
      expect(
        csv,
        '#separator:Comma\r\n'
        '#html:false\r\n'
        'Good morning,Bonjour,English,French,2026-03-07\r\n'
        'gato,noun · cat,Spanish,English,2026-03-07\r\n',
      );
    });

    test('names the detected language as the source', () {
      final csv = PhrasebookCsv.encode([
        _entry('Hallo', 'Hello', source: Language.auto, detected: 'de'),
      ]);
      expect(csv, endsWith('Hallo,Hello,German,French,2026-03-07\r\n'));
    });

    test('quotes fields as RFC 4180 says', () {
      expect(PhrasebookCsv.field('plain'), 'plain');
      expect(PhrasebookCsv.field('a, b'), '"a, b"');
      expect(PhrasebookCsv.field('say "hi"'), '"say ""hi"""');
      expect(PhrasebookCsv.field('two\nlines'), '"two\nlines"');
      expect(PhrasebookCsv.field('cr\rlf'), '"cr\rlf"');
      expect(PhrasebookCsv.field(' padded '), '" padded "');
      // Never taken for one of Anki's header lines.
      expect(PhrasebookCsv.field('#tag'), '"#tag"');
      expect(PhrasebookCsv.field(''), '');
    });

    test('is UTF-8 with a byte order mark', () {
      final bytes = PhrasebookCsv.bytes([_entry('Thank you', 'Merci ✓')]);
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      expect(
        utf8.decode(bytes.sublist(3)),
        PhrasebookCsv.encode([_entry('Thank you', 'Merci ✓')]),
      );
    });

    test('dates are local and zero-padded', () {
      expect(PhrasebookCsv.date(DateTime(987, 1, 2)), '0987-01-02');
    });
  });

  group('PhrasebookCsv rows and parse', () {
    test('encodeRows writes the header and quoted fields', () {
      expect(
        PhrasebookCsv.encodeRows([
          ['a', 'b, c'],
          ['#d', ' e', 'f "g"'],
        ]),
        '#separator:Comma\r\n#html:false\r\n'
        'a,"b, c"\r\n"#d"," e","f ""g"""\r\n',
      );
      expect(PhrasebookCsv.textBytes('x'), [0xEF, 0xBB, 0xBF, 0x78]);
    });

    test('reads its own export back', () {
      final csv = PhrasebookCsv.encode([
        _entry('Hello, "friend"', 'Bonjour'),
        _entry('#tag', 'line\nbreak'),
      ]);
      final table = PhrasebookCsv.parse('${PhrasebookCsv.byteOrderMark}$csv');
      expect(table.separator, ',');
      expect(table.rows, [
        ['Hello, "friend"', 'Bonjour', 'English', 'French', '2026-03-07'],
        ['#tag', 'line\nbreak', 'English', 'French', '2026-03-07'],
      ]);
      expect(table.columns, 5);
    });

    test("follows Anki's separator header", () {
      for (final (name, separator) in [
        ('Tab', '\t'),
        ('Semicolon', ';'),
        ('Pipe', '|'),
        ('Space', ' '),
        ('Colon', ':'),
        ('comma', ','),
        ('/', '/'),
      ]) {
        final table = PhrasebookCsv.parse(
          '#separator:$name\n#html:true\na${separator}b\n',
        );
        expect(table.rows, [
          ['a', 'b'],
        ], reason: name);
        expect(table.separator, separator);
      }
      // An unknown name: the separator is sniffed.
      expect(PhrasebookCsv.parse('#separator:Odd\r\na;b\r\n').rows.single, [
        'a',
        'b',
      ]);
      // Only header lines.
      expect(PhrasebookCsv.parse('#separator:Tab').rows, isEmpty);
      expect(PhrasebookCsv.parse('#html:false\r').rows, isEmpty);
    });

    test('sniffs tabs and semicolons, ignoring quoted ones', () {
      expect(PhrasebookCsv.parse('a\tb\nc\td').rows, [
        ['a', 'b'],
        ['c', 'd'],
      ]);
      expect(PhrasebookCsv.parse('"x;y",b;c\r').separator, ',');
      expect(PhrasebookCsv.parse('a;b;c,d').separator, ';');
      expect(PhrasebookCsv.parse('one\n').rows, [
        ['one'],
      ]);
    });

    test('handles CR line endings, empty lines and lenient quotes', () {
      final table = PhrasebookCsv.parse('a,b\r\rc,"d"x\r"e""f",\n');
      expect(table.rows, [
        ['a', 'b'],
        ['c', 'dx'],
        ['e"f', ''],
      ]);
      expect(PhrasebookCsv.parse('a,"open quote\nnext').rows, [
        ['a', 'open quote\nnext'],
      ]);
      expect(CsvTable.cell(['a'], 3), '');
      expect(PhrasebookCsv.parse('').rows, isEmpty);
      expect(PhrasebookCsv.parse('').columns, 0);
    });

    test('reads at most maxRows rows', () {
      final text = List.filled(PhrasebookCsv.maxRows + 5, 'a,b').join('\n');
      expect(PhrasebookCsv.parse(text).rows, hasLength(PhrasebookCsv.maxRows));
    });
  });
}
