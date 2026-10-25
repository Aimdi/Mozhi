// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:xml/xml_events.dart' show XmlAttributeType;

import 'office_fixtures.dart';

/// Offsets of the local file headers of a ZIP package.
List<int> _localHeaders(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i + 4 <= bytes.length; i++)
      if (data.getUint32(i, Endian.little) == 0x04034b50) i,
  ];
}

void main() {
  group('SourceDocument', () {
    Matcher problem(PackageProblem problem, String message) => throwsA(
      isA<PackageParseException>()
          .having((e) => e.problem, 'problem', problem)
          .having((e) => e.message, 'message', contains(message)),
    );

    test('keeps comments, instructions and CDATA', () {
      final document = SourceDocument.parse(
        '<a><!-- note --><?pi data?><b><![CDATA[x < y]]></b>text</a>',
        part: 'a.xml',
      );
      final root = document.root;
      expect(root.children, hasLength(4));
      expect(root.children[0], isA<SourceMisc>());
      expect(root.children[1], isA<SourceMisc>());
      final cdata = root.elements.single.children.single as SourceText;
      expect(cdata.isCData, isTrue);
      expect(root.text, 'x < ytext');
      expect(root.toString(), 'SourceElement(a)');
      expect(document.of(root.elements.single), '<b><![CDATA[x < y]]></b>');
    });

    test('refuses malformed documents', () {
      expect(
        () => SourceDocument.parse('<a>', part: 'p'),
        problem(PackageProblem.damaged, 'unclosed <a>'),
      );
      expect(
        () => SourceDocument.parse(
          '<a/><!DOCTYPE a>',
          part: 'p',
          allowDoctype: true,
        ),
        problem(PackageProblem.damaged, 'misplaced doctype'),
      );
      expect(
        () => SourceDocument.parse('<a/><![CDATA[x]]>', part: 'p'),
        problem(PackageProblem.damaged, 'CDATA'),
      );
      expect(
        () => SourceDocument.parse('<a/><?xml version="1.0"?>', part: 'p'),
        throwsA(isA<PackageParseException>()),
      );
      expect(
        () => SourceDocument.parse('<a></b>', part: 'p'),
        problem(PackageProblem.damaged, 'mismatched'),
      );
    });

    test('escapes attributes and text', () {
      expect(
        escapeXmlAttribute('a"b\'c&d<e\tf\ng\u0001', .DOUBLE_QUOTE),
        'a&quot;b\'c&amp;d&lt;e&#x9;f&#xA;g',
      );
      expect(
        escapeXmlAttribute('a"b\'c', XmlAttributeType.SINGLE_QUOTE),
        'a"b&apos;c',
      );
      expect(
        escapeXmlText('a<b>&c\u0002\u{1F600}'),
        'a&lt;b&gt;&amp;c\u{1F600}',
      );
    });

    test('style keys ignore marks and compare content', () {
      SourceElement element(String xml) =>
          SourceDocument.parse(xml, part: 'p').root;
      expect(
        styleKey(
          element('<rPr b="1"><x>t<!-- c --></x><lang/></rPr>'),
          ignoredChildren: {'lang'},
        ),
        styleKey(element('<rPr  b="1"><x>t</x></rPr>')),
      );
      expect(
        styleKey(element('<rPr lang="en"/>'), ignoredAttributes: {'lang'}),
        '',
      );
      expect(styleKey(null), '');
    });
  });

  group('rendering', () {
    test('adjacent links and trailing spaces', () {
      final bytes = docx(
        '<w:p><w:hyperlink r:id="a"><w:r><w:t>One</w:t></w:r></w:hyperlink>'
        '<w:hyperlink r:id="b"><w:r><w:t>Two</w:t></w:r></w:hyperlink>'
        '<w:r><w:t xml:space="preserve"> three four five </w:t></w:r></w:p>'
        '<w:p><m:oMath xmlns:m="urn:math"><m:r>x</m:r></m:oMath>'
        '<w:r><w:t xml:space="preserve"> is the answer</w:t></w:r>'
        '<w:smartTag w:element="place"><w:smartTagPr/></w:smartTag></w:p>',
      );
      final document = parsePackagedDocument(bytes, DocumentFormat.docx);
      expect(textsOf(document), [
        '⟨1⟩One⟨2⟩Two⟨3⟩ three four five',
        'is the answer',
      ]);
      final xml = entryText(
        document.render([
          '⟨1⟩Eins⟨2⟩Zwei⟨3⟩ drei vier fünf',
          'ist die Antwort',
        ]),
        'word/document.xml',
      );
      expect(
        xml,
        contains(
          '<w:hyperlink r:id="a"><w:r><w:t xml:space="preserve">Eins</w:t>'
          '</w:r></w:hyperlink><w:hyperlink r:id="b"><w:r>'
          '<w:t xml:space="preserve">Zwei</w:t></w:r></w:hyperlink>'
          '<w:r><w:t xml:space="preserve"> drei vier fünf </w:t></w:r>',
        ),
      );
      expect(
        xml,
        contains(
          '<m:oMath xmlns:m="urn:math"><m:r>x</m:r></m:oMath>'
          '<w:r><w:t xml:space="preserve"> ist die Antwort</w:t></w:r>'
          '<w:smartTag w:element="place"><w:smartTagPr/></w:smartTag>',
        ),
      );
    });

    test('line breaks without run properties in slides', () {
      final bytes = pptx([
        shape(
          '<a:p><a:r><a:t>One</a:t></a:r><a:br/><a:r><a:t>Two</a:t></a:r>'
          '</a:p>',
        ),
      ]);
      final document = parsePackagedDocument(bytes, DocumentFormat.pptx);
      expect(textsOf(document), ['One\nTwo']);
      expect(
        entryText(document.render(['Un\nDeux']), 'ppt/slides/slide1.xml'),
        contains('<a:r><a:t>Un</a:t></a:r><a:br/><a:r><a:t>Deux</a:t></a:r>'),
      );
    });

    test('OpenDocument tabs in translations, covered cells and styles', () {
      final bytes = odf(
        'spreadsheet',
        '<office:spreadsheet><table:table><table:table-row>'
            '<table:covered-table-cell office:value-type="float">'
            '<text:p>Merged</text:p></table:covered-table-cell>'
            '<table:table-cell><text:p>Label</text:p></table:table-cell>'
            '</table:table-row></table:table></office:spreadsheet>',
        masterStyles:
            '<style:master-page style:name="Default"><style:header>'
            '<text:p>Sheet header</text:p></style:header></style:master-page>',
      );
      final document = parsePackagedDocument(bytes, DocumentFormat.ods);
      expect(textsOf(document), ['Label', 'Sheet header']);
      expect(
        entryText(document.render(['Name\tWert']), 'content.xml'),
        contains('<text:p>Name<text:tab/>Wert</text:p>'),
      );

      // Paragraphs of styles.xml outside the master pages stay.
      final styled = zipOf(
        {
          'mimetype': 'application/vnd.oasis.opendocument.text',
          'content.xml':
              '<office:document-content $odfNamespaces><office:body>'
              '<office:text><text:p>Body</text:p></office:text></office:body>'
              '</office:document-content>',
          'styles.xml':
              '<office:document-styles $odfNamespaces><office:styles>'
              '<text:p>Not a header</text:p></office:styles>'
              '</office:document-styles>',
        },
        stored: {'mimetype'},
      );
      expect(textsOf(parsePackagedDocument(styled, DocumentFormat.odt)), [
        'Body',
      ]);
    });

    test('e-book paths are resolved inside the package', () {
      final bytes = zipOf(
        {
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml':
              '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:'
              'container"><rootfiles><rootfile full-path="oebps/book/b.opf"/>'
              '</rootfiles></container>',
          'OEBPS/book/b.opf':
              '<package xmlns="http://www.idpf.org/2007/opf"><manifest>'
              '<item id="a" href="../text/a.xhtml#top" '
              'media-type="application/xhtml+xml"/>'
              '<item id="b" href="./missing.xhtml" '
              'media-type="application/xhtml+xml"/>'
              '<item id="c" href="http://example.com/x.xhtml" '
              'media-type="application/xhtml+xml"/>'
              '<item id="d" media-type="application/xhtml+xml"/>'
              '</manifest><spine><itemref idref="a"/><itemref idref="b"/>'
              '<itemref idref="c"/><itemref idref="d"/><itemref idref="z"/>'
              '<itemref/></spine></package>',
          'OEBPS/text/a.xhtml':
              '<html xmlns="$xhtmlNs"><head><title><b>Bold</b></title></head>'
              '<body><p>Inside</p></body></html>',
        },
        stored: {'mimetype'},
      );
      final document = parsePackagedDocument(bytes, DocumentFormat.epub);
      expect(textsOf(document), ['Bold', 'Inside']);
    });
  });

  group('packages', () {
    test('content types, masters and settings', () {
      const office = 'application/vnd.openxmlformats-officedocument';
      final bytes = zipOf({
        '[Content_Types].xml':
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
            'content-types"><Default Extension="xml" ContentType="'
            'application/xml"/><Default ContentType="x"/><Override '
            'ContentType="y"/><Override PartName="/word/document.xml"/>'
            '<Override PartName="/word/document.xml" ContentType="$office.'
            'wordprocessingml.document.main+xml"/><Override PartName="/word/'
            'settings.xml" ContentType="$office.wordprocessingml.settings+xml"'
            '/><Override PartName="/word/%FF.xml" ContentType="z"/>'
            '<Other/></Types>',
        'word/document.xml':
            '<w:document xmlns:w="$wNs"><w:body><w:p><w:r><w:t>Hi there'
            '</w:t></w:r></w:p></w:body></w:document>',
        'word/settings.xml':
            '<w:settings xmlns:w="$wNs"><w:themeFontLang w:val="en-US"/>'
            '</w:settings>',
        'word/': '',
        'README': 'no extension',
      });
      final document = parsePackagedDocument(
        bytes,
        DocumentFormat.docx,
        targetLanguage: 'it',
      );
      final output = document.render(['Ciao']);
      expect(
        entryText(output, 'word/settings.xml'),
        contains('<w:themeFontLang w:val="it-IT"/>'),
      );
      final entries = entriesOf(output);
      expect(entries.firstWhere((e) => e.name == 'word/').isFile, isFalse);

      final slides = parsePackagedDocument(
        zipOf({
          '[Content_Types].xml':
              '<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
              'content-types"><Override PartName="/p.xml" ContentType="'
              '$office.presentationml.presentation.main+xml"/><Override '
              'PartName="/m.xml" ContentType="$office.presentationml.'
              'slideMaster+xml"/><Override PartName="/s.xml" ContentType="'
              '$office.presentationml.slide+xml"/></Types>',
          'p.xml': '<p:presentation xmlns:p="$pNs"/>',
          'm.xml':
              '<p:sldMaster xmlns:p="$pNs" xmlns:a="$aNs"><a:p><a:r>'
              '<a:rPr lang="en-US"/><a:t>Master prompt</a:t></a:r></a:p>'
              '</p:sldMaster>',
          's.xml':
              '<p:sld xmlns:p="$pNs" xmlns:a="$aNs"><a:p><a:r><a:t>Slide'
              '</a:t></a:r></a:p></p:sld>',
        }),
        DocumentFormat.pptx,
        targetLanguage: 'it',
      );
      expect(textsOf(slides), ['Slide']);
      expect(
        entryText(slides.render(['Diapositiva']), 'm.xml'),
        contains('<a:rPr lang="it-IT"/><a:t>Master prompt</a:t>'),
      );
    });

    test('damaged directories and compressed data', () {
      final bytes = docx('<w:p><w:r><w:t>Hello</w:t></w:r></w:p>');
      // The directory points outside the file.
      final pointer = Uint8List.fromList(bytes);
      ByteData.sublistView(pointer)
          .setUint32(pointer.length - 22 + 16, 0x7FFFFFF0, Endian.little);
      expect(
        () => parsePackagedDocument(pointer, DocumentFormat.docx),
        throwsA(isA<PackageParseException>()),
      );

      // Deflate data with an invalid block type.
      final archive = Archive()
        ..add(ArchiveFile.string('[Content_Types].xml', '<Types/>' * 50));
      final broken = ZipEncoder().encodeBytes(archive);
      final nameLength = broken[26] | broken[27] << 8;
      broken[30 + nameLength] = 0xFF;
      expect(
        () => parsePackagedDocument(broken, DocumentFormat.docx),
        throwsA(
          isA<PackageParseException>().having(
            (e) => e.problem,
            'problem',
            PackageProblem.damaged,
          ),
        ),
      );
    });

    test('entries without a valid time keep a valid one', () {
      final bytes = docx('<w:p><w:r><w:t>Hello</w:t></w:r></w:p>');
      final patched = Uint8List.fromList(bytes);
      for (final offset in _localHeaders(patched)) {
        patched.fillRange(offset + 10, offset + 14, 0);
      }
      final document = parsePackagedDocument(patched, DocumentFormat.docx);
      final output = document.render(['Hallo']);
      for (final entry in entriesOf(output)) {
        expect(entry.lastModDateTime.year, 1980);
      }
    });
  });
}
