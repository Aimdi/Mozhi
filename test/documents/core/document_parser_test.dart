// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseDocument', () {
    test('routes every text format to its parser', () {
      final samples = <DocumentFormat, String>{
        DocumentFormat.html: '<html><body><p>Hello</p></body></html>',
        DocumentFormat.xliff:
            '<xliff version="1.2"><file source-language="en"><body>'
            '<trans-unit id="a"><source>Hello</source></trans-unit>'
            '</body></file></xliff>',
        DocumentFormat.androidStrings:
            '<resources><string name="a">Hello</string></resources>',
        DocumentFormat.po: 'msgid "Hello"\nmsgstr ""\n',
        DocumentFormat.csv: 'Hello,1\n',
        DocumentFormat.tsv: 'Hello\t1\n',
        DocumentFormat.appleStrings: '"a" = "Hello";\n',
        DocumentFormat.xcstrings:
            '{"sourceLanguage": "en", "strings": {"Hello": {}}}',
      };
      for (final MapEntry(key: format, value: text) in samples.entries) {
        final document = parseDocument(text, format, targetLanguage: 'de');
        expect(document.format, format, reason: '$format');
        expect(texts(document), ['Hello'], reason: '$format');
        expectRoundTrip(document, text);
      }
      expect(
        parseDocument(
          samples[DocumentFormat.html]!,
          DocumentFormat.html,
          targetLanguage: 'de',
        ).render(['Hallo']),
        '<html lang="de"><body><p>Hallo</p></body></html>',
      );
      expect(
        () => parseDocument('x', DocumentFormat.docx),
        throwsArgumentError,
      );
    });
  });
}
