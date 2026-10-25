// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';

import 'office_fixtures.dart';

void main() {
  PackagedDocument parse(Uint8List bytes, {String? target = 'de'}) =>
      parsePackagedDocument(bytes, DocumentFormat.docx, targetLanguage: target);

  String documentXml(Uint8List bytes) => entryText(bytes, 'word/document.xml');

  group('DOCX', () {
    test('paragraphs become segments; runs with the same formatting merge', () {
      final bytes = docx(
        '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr>'
        '<w:r w:rsidR="1"><w:t>Hello</w:t></w:r>'
        '<w:proofErr w:type="spellStart"/>'
        '<w:r w:rsidR="2"><w:t xml:space="preserve"> world</w:t></w:r></w:p>'
        '<w:p/>'
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr></w:p>'
        '<w:p><w:r><w:t>2024</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>Second paragraph.</w:t></w:r></w:p>',
      );
      final document = parse(bytes);
      expect(textsOf(document), ['Hello world', 'Second paragraph.']);
      expect(document.format, DocumentFormat.docx);
      expect(document.isEmpty, isFalse);
      expect(document.characterCount, 'Hello world'.length + 17);
      expectRoundTrip(document, bytes, targetLanguage: 'de');

      final output = renderWith(document, {
        'Hello world': 'Hallo Welt',
        'Second paragraph.': 'Zweiter Absatz.',
      });
      final xml = documentXml(output);
      expect(
        xml,
        contains(
          '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr>'
          '<w:r><w:t xml:space="preserve">Hallo Welt</w:t></w:r></w:p>',
        ),
      );
      expect(xml, contains('<w:p/>'));
      expect(xml, contains('<w:p><w:r><w:t>2024</w:t></w:r></w:p>'));
      // The core properties carry the target language.
      expect(
        entryText(output, 'docProps/core.xml'),
        contains('<dc:language>de-DE</dc:language>'),
      );
    });

    test('only translated paragraphs change; other entries are copied', () {
      final bytes = docx(
        '<w:p><w:r><w:t>One</w:t></w:r></w:p>'
        '<w:p w:rsidR="00A1"><w:r><w:t>Two &amp; three</w:t></w:r></w:p>',
        imageStored: true,
      );
      final document = parse(bytes, target: null);
      expect(textsOf(document), ['One', 'Two & three']);
      final output = renderWith(document, {'One': 'Eins & <zwei>'});
      final xml = documentXml(output);
      expect(xml, contains('Eins &amp; &lt;zwei&gt;'));
      expect(
        xml,
        contains(
          '<w:p w:rsidR="00A1"><w:r><w:t>Two &amp; three</w:t></w:r></w:p>',
        ),
      );
      // Without a target language, the language stays.
      expect(
        entryText(output, 'docProps/core.xml'),
        entryText(bytes, 'docProps/core.xml'),
      );
      final before = {for (final e in entriesOf(bytes)) e.name: e};
      final after = entriesOf(output);
      expect(
        [for (final e in after) e.name],
        [for (final e in entriesOf(bytes)) e.name],
      );
      for (final entry in after) {
        if (entry.name == 'word/document.xml') continue;
        expect(
          entry.readBytes(),
          before[entry.name]!.readBytes(),
          reason: entry.name,
        );
        expect(entry.compression, before[entry.name]!.compression);
      }
    });

    test('formatting runs, hyperlinks, tabs and footnote references', () {
      final bytes = docx(
        '<w:p><w:r><w:t xml:space="preserve">Read </w:t></w:r>'
        '<w:r><w:rPr><w:b/><w:lang w:val="en-GB"/></w:rPr>'
        '<w:t>this</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> and </w:t></w:r>'
        '<w:hyperlink r:id="rId2"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/>'
        '</w:rPr><w:t>that page</w:t></w:r></w:hyperlink>'
        '<w:r><w:tab/><w:t>now</w:t></w:r>'
        '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr>'
        '<w:footnoteReference w:id="1"/></w:r>'
        '<w:r><w:t>.</w:t></w:r></w:p>',
        footnotes:
            '<w:footnote w:id="1"><w:p><w:r><w:footnoteRef/></w:r>'
            '<w:r><w:t xml:space="preserve"> A note.</w:t></w:r></w:p>'
            '</w:footnote>',
      );
      final document = parse(bytes);
      expect(textsOf(document), [
        'Read ⟨1⟩this⟨2⟩ and ⟨3⟩that page⟨4⟩now⟨5⟩.',
        'A note.',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'de');

      final output = renderWith(document, {
        'Read ⟨1⟩this⟨2⟩ and ⟨3⟩that page⟨4⟩now⟨5⟩.':
            'Lies ⟨1⟩das⟨2⟩ und ⟨3⟩jene Seite⟨4⟩jetzt⟨5⟩.',
        'A note.': 'Eine Notiz.',
      });
      final xml = documentXml(output);
      expect(
        xml,
        contains(
          '<w:r><w:rPr><w:b/><w:lang w:val="de-DE"/></w:rPr>'
          '<w:t xml:space="preserve">das</w:t></w:r>',
        ),
      );
      expect(
        xml,
        contains(
          '<w:hyperlink r:id="rId2"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/>'
          '</w:rPr><w:t xml:space="preserve">jene Seite</w:t></w:r>'
          '</w:hyperlink><w:r><w:tab/></w:r>',
        ),
      );
      expect(xml, contains('<w:footnoteReference w:id="1"/>'));
      expect(
        entryText(output, 'word/footnotes.xml'),
        contains(
          '<w:r><w:footnoteRef/></w:r>'
          '<w:r><w:t xml:space="preserve"> Eine Notiz.</w:t></w:r>',
        ),
      );
      expect(textsOf(parse(output)).first, contains('jene Seite'));
    });

    test('placeholders the engine moves, drops or repeats', () {
      final bytes = docx(
        '<w:p><w:r><w:t xml:space="preserve">Press </w:t></w:r>'
        '<w:r><w:rPr><w:b/></w:rPr><w:t>Save</w:t></w:r>'
        '<w:r><w:t xml:space="preserve"> now</w:t></w:r>'
        '<w:r><w:drawing><wp:inline xmlns:wp="urn:wp"/></w:drawing></w:r>'
        '<w:r><w:t>.</w:t></w:r></w:p>',
      );
      final document = parse(bytes);
      expect(textsOf(document), ['Press ⟨1⟩Save⟨2⟩ now⟨3⟩.']);

      // Reordered: the bold text follows its placeholders.
      var xml = documentXml(document.render(['⟨1⟩Speichern⟨2⟩ drücken ⟨3⟩.']));
      expect(
        xml,
        contains(
          '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Speichern'
          '</w:t></w:r><w:r><w:t xml:space="preserve"> drücken</w:t></w:r>'
          '<w:r><w:drawing>',
        ),
      );
      // Dropped and repeated placeholders: the image is never lost.
      xml = documentXml(document.render(['Jetzt ⟨1⟩speichern⟨1⟩⟨9⟩.']));
      expect(xml, contains('<w:drawing>'));
      expect(xml, isNot(contains('⟨')));
      expect(xml, contains('speichern'));
      // Spaces engines add around glued placeholders are removed.
      xml = documentXml(
        document.render(['Drücke ⟨1⟩ Speichern ⟨2⟩ jetzt ⟨3⟩ .']),
      );
      expect(xml, contains('<w:t xml:space="preserve">Speichern</w:t>'));
      expect(xml, contains('<w:t xml:space="preserve">.</w:t>'));
    });

    test('line breaks, page breaks and special hyphens', () {
      final bytes = docx(
        '<w:p><w:r><w:t>First line</w:t><w:br/><w:t>second</w:t>'
        '<w:noBreakHyphen/><w:t>line</w:t><w:softHyphen/><w:t>x</w:t>'
        '<w:br w:type="page"/><w:t>next page</w:t>'
        '<w:lastRenderedPageBreak/><w:cr/><w:t>end</w:t></w:r></w:p>',
      );
      final document = parse(bytes);
      expect(textsOf(document), ['First line\nsecond‑line­x⟨1⟩next page\nend']);
      final xml = documentXml(
        document.render(['Erste\nzweite‑Zeile­x⟨1⟩Seite\nEnde']),
      );
      expect(
        xml,
        contains(
          '<w:t xml:space="preserve">Erste</w:t><w:br/>'
          '<w:t xml:space="preserve">zweite</w:t><w:noBreakHyphen/>'
          '<w:t xml:space="preserve">Zeile</w:t><w:softHyphen/>',
        ),
      );
      expect(xml, contains('<w:br w:type="page"/>'));
    });

    test('fields keep their instructions and their order', () {
      final bytes = docx(
        '<w:p><w:r><w:t xml:space="preserve">See </w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:instrText xml:space="preserve"> HYPERLINK '
        '"https://a.example" </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        '<w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>the site</w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
        '<w:r><w:t xml:space="preserve"> for more.</w:t></w:r></w:p>'
        '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:instrText>PAGE</w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
      );
      final document = parse(bytes);
      expect(textsOf(document), ['See ⟨1⟩the site⟨2⟩ for more.']);
      // The engine swaps the field's placeholders: their order is kept.
      final xml = documentXml(document.render(['Mehr auf ⟨2⟩der Seite⟨1⟩.']));
      final begin = xml.indexOf('w:fldCharType="begin"');
      final instruction = xml.indexOf('HYPERLINK');
      final end = xml.indexOf('w:fldCharType="end"');
      expect(begin, lessThan(instruction));
      expect(instruction, lessThan(end));
      expect(xml, contains(' HYPERLINK "https://a.example" '));
      expect(xml.indexOf('der Seite'), lessThan(end));
    });

    test('tables, text boxes and alternate content', () {
      const box =
          '<wps:txbx xmlns:wps="urn:wps"><w:txbxContent>'
          '<w:p><w:r><w:t>Boxed text</w:t></w:r></w:p>'
          '</w:txbxContent></wps:txbx>';
      final bytes = docx(
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>12</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p><w:r><w:t xml:space="preserve">Before </w:t></w:r>'
        '<w:r><mc:AlternateContent xmlns:mc="urn:mc">'
        '<mc:Choice Requires="wps"><w:drawing>$box</w:drawing></mc:Choice>'
        '<mc:Fallback><w:pict>$box</w:pict></mc:Fallback>'
        '</mc:AlternateContent></w:r>'
        '<w:r><w:t xml:space="preserve"> after.</w:t></w:r></w:p>'
        '<w:p><w:r><w:drawing>$box</w:drawing></w:r></w:p>',
      );
      final document = parse(bytes);
      // The text box appears three times but is one segment.
      expect(textsOf(document), ['Cell A', 'Before ⟨1⟩ after.', 'Boxed text']);
      expectRoundTrip(document, bytes, targetLanguage: 'de');
      final xml = documentXml(
        renderWith(document, {'Boxed text': 'Text im Kasten'}),
      );
      expect('Text im Kasten'.allMatches(xml), hasLength(3));
      expect(xml, contains('<w:t xml:space="preserve"> after.</w:t>'));
      expect(xml, isNot(contains('Boxed text')));
    });

    test('tracked changes, content controls, bookmarks and comments', () {
      final bytes = docx(
        '<w:p><w:bookmarkStart w:id="0" w:name="intro"/>'
        '<w:r><w:t xml:space="preserve">Keep </w:t></w:r>'
        '<w:del w:id="1" w:author="A"><w:r><w:delText>old</w:delText></w:r>'
        '</w:del>'
        '<w:ins w:id="2" w:author="A"><w:r><w:t>new</w:t></w:r></w:ins>'
        '<w:commentRangeStart w:id="3"/>'
        '<w:r><w:t xml:space="preserve"> text</w:t></w:r>'
        '<w:commentRangeEnd w:id="3"/>'
        '<w:sdt><w:sdtPr><w:alias w:val="Name"/></w:sdtPr><w:sdtContent>'
        '<w:r><w:t xml:space="preserve"> here</w:t></w:r></w:sdtContent>'
        '</w:sdt><w:bookmarkEnd w:id="0"/></w:p>',
      );
      final document = parse(bytes);
      expect(textsOf(document), ['Keep ⟨1⟩new⟨2⟩ text⟨3⟩ here⟨4⟩']);
      expectRoundTrip(document, bytes, targetLanguage: 'de');
      final xml = documentXml(
        document.render(['Behalte ⟨1⟩neuen⟨2⟩ Text⟨3⟩ hier⟨4⟩']),
      );
      expect(xml, startsWith(declaration));
      expect(xml, contains('<w:delText>old</w:delText>'));
      expect(
        xml,
        contains(
          '<w:ins w:id="2" w:author="A"><w:r>'
          '<w:t xml:space="preserve">neuen</w:t></w:r></w:ins>',
        ),
      );
      expect(
        xml,
        contains(
          '<w:sdt><w:sdtPr><w:alias w:val="Name"/></w:sdtPr><w:sdtContent>'
          '<w:r><w:t xml:space="preserve"> hier</w:t></w:r></w:sdtContent>'
          '</w:sdt><w:bookmarkEnd w:id="0"/>',
        ),
      );
      expect(xml, contains('<w:bookmarkStart w:id="0" w:name="intro"/>'));
    });

    test('headers, styles and settings record the target language', () {
      final bytes = docx(
        '<w:p><w:r><w:rPr><w:rtl/><w:lang w:bidi="he-IL"/></w:rPr>'
        '<w:t>שלום עולם</w:t></w:r></w:p>',
        header: '<w:p><w:r><w:t>Header text</w:t></w:r></w:p>',
        styles:
            '<w:docDefaults><w:rPrDefault><w:rPr><w:lang w:val="en-US" '
            'w:eastAsia="ja-JP" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>'
            '</w:docDefaults>',
        extra: {
          'word/settings.xml':
              '$declaration<w:settings xmlns:w="$wNs">'
              '<w:themeFontLang w:val="en-US"/></w:settings>',
        },
      );
      final document = parse(bytes, target: 'ar');
      expect(textsOf(document), ['שלום עולם', 'Header text']);
      final output = renderWith(document, {'שלום עולם': 'مرحبا بالعالم'});
      final xml = documentXml(output);
      expect(
        xml,
        contains(
          '<w:r><w:rPr><w:rtl/><w:lang w:bidi="ar-SA"/></w:rPr>'
          '<w:t xml:space="preserve">مرحبا بالعالم</w:t></w:r>',
        ),
      );
      expect(
        entryText(output, 'word/styles.xml'),
        contains('<w:lang w:val="en-US" w:eastAsia="ja-JP" w:bidi="ar-SA"/>'),
      );
      // settings.xml has no content type override: copied as it is.
      expect(
        entryText(output, 'word/settings.xml'),
        contains('<w:themeFontLang w:val="en-US"/>'),
      );
      // The header was not translated.
      expect(
        entryText(output, 'word/header1.xml'),
        entryText(bytes, 'word/header1.xml'),
      );

      final german = parse(bytes);
      final styled = renderWith(german, {'Header text': 'Kopfzeile'});
      expect(
        entryText(styled, 'word/styles.xml'),
        contains('<w:lang w:val="de-DE" w:eastAsia="ja-JP" w:bidi="ar-SA"/>'),
      );
      // The untranslated Hebrew paragraph keeps its language.
      expect(documentXml(styled), contains('<w:lang w:bidi="he-IL"/>'));

      final japanese = (parse(bytes) as OfficePackage).withTargetLanguage('ja');
      expect(
        entryText(
          renderWith(japanese, {'Header text': 'ヘッダー'}),
          'word/styles.xml',
        ),
        contains('w:eastAsia="ja-JP"'),
      );
    });

    test('strict documents and other prefixes', () {
      const strict = 'http://purl.oclc.org/ooxml/wordprocessingml/main';
      final bytes = zipOf({
        '[Content_Types].xml':
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
            'content-types"><Override PartName="/word/document.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.'
            'wordprocessingml.document.main+xml"/></Types>',
        'word/document.xml':
            '<x:document xmlns:x="$strict"><x:body><x:p><x:r>'
            '<x:t>Strict text</x:t></x:r></x:p></x:body></x:document>',
      });
      final document = parse(bytes);
      expect(textsOf(document), ['Strict text']);
      expect(
        documentXml(document.render(['Strenger Text'])),
        contains('<x:r><x:t xml:space="preserve">Strenger Text</x:t></x:r>'),
      );
    });

    test('refuses packages that are not Word documents', () {
      expect(
        () => parse(xlsx(['<si><t>x</t></si>'])),
        throwsA(
          isA<PackageParseException>().having(
            (e) => e.problem,
            'problem',
            PackageProblem.damaged,
          ),
        ),
      );
      expect(
        () => parse(zipOf({'word/document.xml': '<w:document/>'})),
        throwsA(isA<DocumentParseException>()),
      );
    });

    test('malformed XML is reported as damaged', () {
      final bytes = docx('<w:p><w:r><w:t>Broken</w:r></w:p>');
      expect(
        () => parse(bytes),
        throwsA(
          isA<PackageParseException>()
              .having((e) => e.problem, 'problem', PackageProblem.damaged)
              .having((e) => e.message, 'message', contains('word/document')),
        ),
      );
    });
  });
}
