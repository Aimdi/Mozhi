import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parsePlainText', () {
    test('splits paragraphs on blank lines', () {
      const text = 'Hello world.\nSecond line.\n\nNew paragraph.\n';
      final document = parsePlainText(text);
      expect(document.format, DocumentFormat.plainText);
      expect(texts(document), ['Hello world.\nSecond line.', 'New paragraph.']);
      expectRoundTrip(document, text);
      expect(
        renderUpper(document),
        'HELLO WORLD.\nSECOND LINE.\n\nNEW PARAGRAPH.\n',
      );
    });

    test('keeps indentation, trailing spaces and many blank lines', () {
      const text = '\n\n   Indented start  \n\n\n\tTabbed\n   \n end';
      final document = parsePlainText(text);
      expect(texts(document), ['Indented start', 'Tabbed', 'end']);
      expectRoundTrip(document, text);
      expect(
        renderUpper(document),
        '\n\n   INDENTED START  \n\n\n\tTABBED\n   \n END',
      );
    });

    test('keeps CRLF line endings, also in translations', () {
      const text = 'One\r\ntwo\r\n\r\nThree\r\n';
      final document = parsePlainText(text);
      expect(texts(document), ['One\ntwo', 'Three']);
      expectRoundTrip(document, text);
      expect(
        document.render(['Uno\ndos', 'Tres']),
        'Uno\r\ndos\r\n\r\nTres\r\n',
      );
    });

    test('protects URLs and e-mail addresses', () {
      const text = 'Visit https://example.com/a?b=1. Mail me@example.org';
      final document = parsePlainText(text);
      expect(texts(document), ['Visit ⟨1⟩. Mail ⟨2⟩']);
      expectRoundTrip(document, text);
      expect(
        document.render(['Besuche ⟨1⟩. Schreib an ⟨2⟩']),
        'Besuche https://example.com/a?b=1. Schreib an me@example.org',
      );
    });

    test('skips paragraphs without letters', () {
      const text = '12345\n\n---\n\nWords';
      final document = parsePlainText(text);
      expect(texts(document), ['Words']);
      expectRoundTrip(document, text);
    });

    test('handles empty and whitespace-only text', () {
      expect(parsePlainText('').segments, isEmpty);
      expectRoundTrip(parsePlainText(''), '');
      expectRoundTrip(parsePlainText(' \n\t\n'), ' \n\t\n');
    });

    test('translates scripts other than Latin', () {
      const text = 'Привет мир\n\nこんにちは';
      final document = parsePlainText(text);
      expect(texts(document), ['Привет мир', 'こんにちは']);
      expectRoundTrip(document, text);
    });
  });
}
