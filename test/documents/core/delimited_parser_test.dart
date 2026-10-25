// Markup fixtures are built from adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/parsers/delimited_parser.dart';

import '../helpers/document_helpers.dart';

void main() {
  group('parseDelimited', () {
    const products =
        'id,name,price,description,url,released,sku\r\n'
        '1,Red chair,19.99,"A comfortable chair, made of ""real"" wood",'
        'https://example.com/1,2024-01-31,CH-001\r\n'
        '2,Blue table,149,"Seats four.\r\nFolds away.",'
        'https://example.com/2,2024-02-01,TB-002\r\n'
        '3,Lamp,"1,299.00",,https://example.com/3,2024-03-15,LM-003\r\n';

    test('round-trips and translates text columns only', () {
      final document = parseDelimited(products, DocumentFormat.csv);
      expect(document.format, DocumentFormat.csv);
      expectRoundTrip(document, products);
      expect(texts(document), [
        'Red chair',
        'A comfortable chair, made of "real" wood',
        'Blue table',
        'Seats four.\nFolds away.',
        'Lamp',
      ]);
      expect(document.segments.first.label, 'name:2');
    });

    test('quotes translations that need it', () {
      final document = parseDelimited(products, DocumentFormat.csv);
      final output = document.render([
        'Chaise rouge, confortable',
        'Une chaise "confortable"',
        'Table bleue',
        'Quatre places.\nSe replie.',
        'Lampe',
      ]);
      expect(
        output,
        '${'id,name,price,description,url,released,sku\r\n'
            '1,"Chaise rouge, confortable",19.99,"Une chaise ""confortable""",'
            'https://example.com/1,2024-01-31,CH-001\r\n'
            '2,Table bleue,149,"Quatre places.\r\nSe replie.",'
            'https://example.com/2,2024-02-01,TB-002\r\n'}'
        '3,Lampe,"1,299.00",,https://example.com/3,2024-03-15,LM-003\r\n',
      );
    });

    test('detects semicolons and keeps a header-less phrase list', () {
      const european = 'Bonjour;Hello\nMerci beaucoup;Thank you\n';
      final document = parseDelimited(european, DocumentFormat.csv);
      expectRoundTrip(document, european);
      // Two short distinct labels: read as a header.
      expect(texts(document), ['Merci beaucoup', 'Thank you']);

      const phrases = 'Good morning\nThank you\nSee you soon\n';
      expect(texts(parseDelimited(phrases, DocumentFormat.csv)), [
        'Good morning',
        'Thank you',
        'See you soon',
      ]);
      const titled = 'text\nGood morning\nThank you\n';
      expect(texts(parseDelimited(titled, DocumentFormat.csv)), [
        'Good morning',
        'Thank you',
      ]);
    });

    test('keeps code columns and formulas', () {
      const sheet =
          'status\tnote\n'
          'active\tCall back tomorrow\n'
          'active\t=SUM(A1:A3)\n'
          'inactive\tNo answer\n'
          'active\t42\n';
      final document = parseDelimited(sheet, DocumentFormat.tsv);
      expectRoundTrip(document, sheet);
      expect(texts(document), ['Call back tomorrow', 'No answer']);
      final output = document.render(['Morgen\tzurückrufen', 'Keine\nAntwort']);
      expect(output, contains('active\tMorgen zurückrufen\n'));
      expect(output, contains('inactive\tKeine Antwort\n'));
    });

    test('keeps a byte order mark and odd fields', () {
      const odd = '\uFEFFname,comment\nAda,"quoted"tail\n';
      final document = parseDelimited(odd, DocumentFormat.csv);
      expectRoundTrip(document, odd);
      expect(texts(document), ['Ada']);
    });

    test('rejects an unterminated quoted field', () {
      expect(
        () => parseDelimited('a,b\n"open,c\n', DocumentFormat.csv),
        throwsA(
          isA<DocumentParseException>().having(
            (error) => error.message,
            'message',
            contains('line 2'),
          ),
        ),
      );
    });
  });

  test('keeps cells whose words are all placeholders', () {
    const sheet = 'title,body\n{{name}},Some text here\n';
    final document = parseDelimited(sheet, DocumentFormat.csv);
    expectRoundTrip(document, sheet);
    expect(texts(document), ['Some text here']);
    expect(
      () => parseDelimited('a', DocumentFormat.po),
      throwsA(isA<AssertionError>()),
    );
  });
}
