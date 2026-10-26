// Hostile inputs are built from repeated adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

/// About the size of each hostile input, in characters.
const _size = 200000;

/// Each input is parsed and rendered (or sniffed) within this: a parser
/// or pattern that backtracks quadratically takes minutes instead.
const _budget = Duration(seconds: 1);

String _many(String text) => text * (_size ~/ text.length);

String _xliff(String source) =>
    '<xliff version="1.2" xmlns="urn:oasis:names:tc:xliff:document:1.2">'
    '<file source-language="en" datatype="plaintext" original="a"><body>'
    '<trans-unit id="1"><source>$source</source></trans-unit>'
    '</body></file></xliff>';

String _android(String value) =>
    '<resources><string name="x">$value</string></resources>';

String _xcstrings(String value) =>
    '{"sourceLanguage":"en","strings":{"k":{"localizations":{"en":'
    '{"stringUnit":{"state":"translated","value":"$value"}}}}},'
    '"version":"1.0"}';

void main() {
  final spaces = ' ' * _size;
  final cases = <String, (DocumentFormat, String)>{
    // CSV and TSV cells.
    'CSV: an e-mail-like cell': (
      DocumentFormat.csv,
      'id,text\n1,a@${'.' * _size} b\n',
    ),
    'CSV: an identifier-like cell': (
      DocumentFormat.csv,
      'id,text\n1,a${'1' * _size}!\n',
    ),
    'CSV: a code-like cell': (
      DocumentFormat.csv,
      'id,text\n1,a${_many('-a1')}!\n',
    ),
    'CSV: a number-like cell': (
      DocumentFormat.csv,
      'id,text\n1,1${_many(',111')}x\n',
    ),
    'CSV: unclosed comments in a cell': (
      DocumentFormat.csv,
      'id,text\n1,Hi ${_many('<!--')}\n',
    ),
    'CSV: a tag followed by spaces': (
      DocumentFormat.csv,
      'id,text\n1,Hi <a$spaces\n',
    ),
    'CSV: spaces inside a cell': (
      DocumentFormat.csv,
      'id,text\n1,Hi${spaces}x\n',
    ),
    'CSV: a conversion with zeros': (
      DocumentFormat.csv,
      'id,text\n1,Hi %${'0' * _size}!\n',
    ),
    'CSV: doubled quotes': (DocumentFormat.csv, 'a,b\n"${_many('""')}",x\n'),
    'TSV: spaces inside a cell': (
      DocumentFormat.tsv,
      'id\ttext\n1\tHi${spaces}x\n',
    ),
    // HTML.
    'HTML: entity-like text': (
      DocumentFormat.html,
      '<p>Hello ${_many('&a')} world</p>',
    ),
    'HTML: escaped unclosed comments': (
      DocumentFormat.html,
      '<p>Hi ${_many('&lt;!--')}</p>',
    ),
    'HTML: an escaped tag followed by spaces': (
      DocumentFormat.html,
      '<p>Hi &lt;a$spaces</p>',
    ),
    'HTML: spaces inside a paragraph': (
      DocumentFormat.html,
      '<p>Hi${spaces}x</p>',
    ),
    'HTML: unclosed inline elements': (
      DocumentFormat.html,
      '<p>${_many('<span>a ')}</p>',
    ),
    // XLIFF.
    'XLIFF: escaped unclosed comments': (
      DocumentFormat.xliff,
      _xliff('Hi ${_many('&lt;!--')}'),
    ),
    'XLIFF: an escaped tag followed by spaces': (
      DocumentFormat.xliff,
      _xliff('Hi &lt;a$spaces'),
    ),
    // Android strings.
    'Android: escaped line breaks': (
      DocumentFormat.androidStrings,
      _android('Hello ${_many(r'\n')}'),
    ),
    'Android: backslashes': (
      DocumentFormat.androidStrings,
      _android('Hello ${r'\' * _size}'),
    ),
    'Android: spaces inside a string': (
      DocumentFormat.androidStrings,
      _android('Hello${spaces}x'),
    ),
    'Android: a reference-like value': (
      DocumentFormat.androidStrings,
      _android('@${_many('a.')}!'),
    ),
    'Android: a conversion with zeros': (
      DocumentFormat.androidStrings,
      _android('Hi %${'0' * _size}!'),
    ),
    // PO.
    'PO: a tag followed by spaces': (
      DocumentFormat.po,
      'msgid "Hi <a$spaces"\nmsgstr ""\n',
    ),
    'PO: unclosed comments': (
      DocumentFormat.po,
      'msgid "Hi ${_many('<!--')}"\nmsgstr ""\n',
    ),
    'PO: a Python conversion with zeros': (
      DocumentFormat.po,
      'msgid "Hi %(a)${'0' * _size}!"\nmsgstr ""\n',
    ),
    'PO: many entries': (
      DocumentFormat.po,
      _many('msgid "Hello world"\nmsgstr ""\n\n'),
    ),
    // Apple strings and string catalogues.
    'Strings: unclosed comments in a value': (
      DocumentFormat.appleStrings,
      '"k" = "Hello ${_many('<!--')}";\n',
    ),
    'Strings: a conversion with zeros': (
      DocumentFormat.appleStrings,
      '"k" = "Hi %${'0' * _size}@";\n',
    ),
    'Strings: escaped backslashes': (
      DocumentFormat.appleStrings,
      '"k" = "Hello ${_many(r'\\')}";\n',
    ),
    'xcstrings: unclosed comments': (
      DocumentFormat.xcstrings,
      _xcstrings('Hello ${_many('<!--')}'),
    ),
    'xcstrings: a tag followed by spaces': (
      DocumentFormat.xcstrings,
      _xcstrings('Hello <a$spaces'),
    ),
    // The other text formats share the builder and patterns.
    'JSON: spaces inside a value': (
      DocumentFormat.json,
      '{"a":"Hello${spaces}x"}',
    ),
    'JSON: an identifier-like value': (
      DocumentFormat.json,
      '{"a":"a${'1' * _size}!"}',
    ),
    'JSON: a tag followed by spaces': (
      DocumentFormat.json,
      '{"a":"Hi <a$spaces"}',
    ),
    'JSON: a conversion with zeros': (
      DocumentFormat.json,
      '{"a":"Hi %${'0' * _size}!"}',
    ),
    'Markdown: spaces inside a heading': (
      DocumentFormat.markdown,
      '# Hi${spaces}x\n',
    ),
    'Markdown: a blank line under a table row': (
      DocumentFormat.markdown,
      '|a|\n${spaces}x\n',
    ),
    'Markdown: footnote and image openers': (
      DocumentFormat.markdown,
      'Hi ${_many('[^![')}\n',
    ),
    'Markdown: an image with a long destination': (
      DocumentFormat.markdown,
      'Hi ![](${'a' * _size}x\n',
    ),
    'Plain text: spaces inside a paragraph': (
      DocumentFormat.plainText,
      'Hi${spaces}x\n',
    ),
    'Subtitles: spaces inside a cue': (
      DocumentFormat.srt,
      '1\n00:00:01,000 --> 00:00:02,000\nHi${spaces}x\n',
    ),
  };

  group('parsing hostile input takes linear time', () {
    for (final MapEntry(key: name, value: (format, text)) in cases.entries) {
      test(name, () {
        final watch = Stopwatch()..start();
        final document = parseDocument(text, format, targetLanguage: 'de');
        final output = document.render([
          for (final segment in document.segments) '${segment.text} x',
        ]);
        const Chunker().planSegments(
          document.segments,
          Chunker.encodingFor(format),
        );
        expect(watch.elapsed, lessThan(_budget));
        expect(output, isNotEmpty);
      });
    }
  });

  group('sniffing hostile input takes linear time', () {
    final texts = {
      'declarations': _many('<?a?>'),
      'comments': _many('<!---->'),
      'a doctype followed by spaces': '<!DOCTYPE${spaces}x',
      'unclosed block comments': _many('/*a'),
      'quoted unclosed block comments': '"${_many('/*a')}',
      'link openers': '[' * _size,
      'a blank line under a table row': '|a|\n${spaces}x',
      'many tabs': 'a\tb\n${'\t' * _size}x',
    };
    for (final MapEntry(key: name, value: text) in texts.entries) {
      test(name, () {
        final watch = Stopwatch()..start();
        DocumentFormat.sniff(text);
        expect(watch.elapsed, lessThan(_budget));
      });
    }
  });
}
