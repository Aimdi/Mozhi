import 'package:mozhi_cli/src/output/format.dart';
import 'package:mozhi_cli/src/output/json_output.dart';
import 'package:mozhi_cli/src/output/streaming_printer.dart';
import 'package:mozhi_cli/src/output/table.dart';
import 'package:mozhi_cli/src/output/text_width.dart';
import 'package:test/test.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('displayWidth', () {
    test('counts wide, zero-width and ANSI correctly', () {
      expect(displayWidth('abc'), 3);
      expect(displayWidth('日本語'), 6);
      expect(displayWidth('한국'), 4);
      expect(displayWidth('é'), 1);
      expect(displayWidth('\x1B[1mbold\x1B[0m'), 4);
      expect(displayWidth('👍'), 2);
      expect(displayWidth('\t'), 0);
      expect(padDisplay('日本', 6), '日本  ');
      expect(padDisplay('long', 2), 'long');
    });
  });

  test('renderTable aligns columns', () {
    final table = renderTable(
      ['A', 'B', 'C'],
      [
        ['日本', 'x', ''],
        ['abcdef', 'yy'],
      ],
      styleHeader: (h) => '<$h>',
    );
    expect(table.split('\n'), ['<A>       <B>   <C>', '日本    x', 'abcdef  yy']);
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(milliseconds: 999)), '999 ms');
    expect(formatDuration(const Duration(milliseconds: 1250)), '1.3 s');
  });

  group('StreamingPrinter', () {
    late StringBuffer out;
    StreamingPrinter printer({int columns = 10, int lines = 5}) =>
        StreamingPrinter(write: out.write, columns: columns, lines: lines);

    setUp(() => out = StringBuffer());

    test('appends growing snapshots', () {
      printer()
        ..update('Hel')
        ..update('Hel')
        ..update('Hello')
        ..finish('Hello!');
      expect(out.toString(), 'Hello!\n');
    });

    test('redraws multi-line output that changed', () {
      final p = printer()
        ..update('"0123456789abc')
        ..update('different')
        ..finish('0123456789abc');
      expect(out.toString(), '"0123456789abc\r\x1B[1A\x1B[J0123456789abc\n');
      expect(p.printed, '0123456789abc');
    });

    test('leaves output that scrolled away', () {
      printer(lines: 2)
        ..update('a\nb\nc')
        ..finish('x');
      expect(out.toString(), 'a\nb\nc\n');
    });

    test('abort erases or ends the line', () {
      printer().abort();
      expect(out.toString(), isEmpty);
      printer()
        ..update('abc')
        ..abort();
      expect(out.toString(), 'abc\r\x1B[J');
      out.clear();
      printer(lines: 1)
        ..update('abc')
        ..abort();
      expect(out.toString(), 'abc\n');
    });

    test('finish without streamed text prints the text', () {
      printer().finish('x');
      expect(out.toString(), 'x\n');
    });

    test('rowsOf wraps long and wide lines', () {
      expect(StreamingPrinter.rowsOf('', 10), 1);
      expect(StreamingPrinter.rowsOf('a' * 10, 10), 1);
      expect(StreamingPrinter.rowsOf('a' * 11, 10), 2);
      expect(StreamingPrinter.rowsOf('日本語日本語', 10), 2);
      expect(StreamingPrinter.rowsOf('a\n\nb', 0), 3);
    });
  });

  group('JSON', () {
    test('encodes results with every detail', () {
      const result = TranslationResult(
        engineId: 'mozhi:google',
        engineName: 'Google',
        text: 'Hi',
        sourceTransliteration: 'src',
        wordChoices: [
          WordChoice(
            word: 'hi',
            definition: 'greeting',
            examplesSource: ['a'],
            examplesTarget: ['b'],
          ),
          WordChoice(word: 'yo'),
        ],
        sourceSynonyms: ['hey'],
        targetSynonyms: ['hello'],
      );
      expect(
        translationJson(
          result,
          source: const Language(code: 'fr', name: 'French'),
          target: const Language.custom('Pirate'),
        ),
        {
          'engine': 'mozhi:google',
          'engineName': 'Google',
          'source': 'fr',
          'target': 'Pirate',
          'text': 'Hi',
          'sourceTransliteration': 'src',
          'wordChoices': [
            {
              'word': 'hi',
              'definition': 'greeting',
              'examplesSource': ['a'],
              'examplesTarget': ['b'],
            },
            {'word': 'yo'},
          ],
          'sourceSynonyms': ['hey'],
          'targetSynonyms': ['hello'],
        },
      );
      expect(languageJson(const Language.custom('Pirate')), {
        'code': 'Pirate',
        'name': 'Pirate',
        'custom': true,
      });
      expect(encodeJson({'a': 1}), '{\n  "a": 1\n}');
    });
  });
}
