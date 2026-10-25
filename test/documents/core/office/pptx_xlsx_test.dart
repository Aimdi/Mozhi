// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';

import 'office_fixtures.dart';

void main() {
  group('PPTX', () {
    PackagedDocument parse(Uint8List bytes, {String? target = 'fr'}) =>
        parsePackagedDocument(
          bytes,
          DocumentFormat.pptx,
          targetLanguage: target,
        );

    test('slide and notes paragraphs with runs, breaks and fields', () {
      final bytes = pptx([
        shape(
          '<a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="en-US" dirty="0"/>'
          '<a:t>Quarterly</a:t></a:r><a:r><a:rPr lang="en-US" err="1"/>'
          '<a:t xml:space="preserve"> results</a:t></a:r>'
          '<a:endParaRPr lang="en-US"/></a:p>'
          '<a:p><a:r><a:rPr lang="en-US" b="1"/><a:t>Bold</a:t></a:r>'
          '<a:r><a:rPr lang="en-US"/><a:t xml:space="preserve"> and </a:t>'
          '</a:r><a:r><a:rPr lang="en-US"><a:hlinkClick r:id="rId2"/>'
          '</a:rPr><a:t>a link</a:t></a:r><a:br><a:rPr lang="en-US"/>'
          '</a:br><a:r><a:rPr lang="en-US"/><a:t>Line two</a:t></a:r></a:p>'
          '<a:p><a:fld id="{1}" type="slidenum"><a:rPr lang="en-US"/>'
          '<a:t>3</a:t></a:fld></a:p>'
          '<a:p><a:endParaRPr lang="en-US"/></a:p>',
        ),
        shape(
          '<a:p><a:r><a:t>Quarterly results</a:t></a:r></a:p>'
          '<a:p><a:r><a:t>Slide </a:t></a:r><a:fld id="{2}" '
          'type="slidenum"><a:t>2</a:t></a:fld><a:r><a:t> of 2</a:t></a:r>'
          '</a:p>',
        ),
      ], notes: shape('<a:p><a:r><a:t>Speaker notes.</a:t></a:r></a:p>'));
      final document = parse(bytes);
      expect(textsOf(document), [
        'Quarterly results',
        '⟨1⟩Bold⟨2⟩ and ⟨3⟩a link⟨4⟩\nLine two',
        'Slide ⟨1⟩ of 2',
        'Speaker notes.',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'fr');

      final output = renderWith(document, {
        'Quarterly results': 'Résultats trimestriels',
        '⟨1⟩Bold⟨2⟩ and ⟨3⟩a link⟨4⟩\nLine two':
            '⟨1⟩Gras⟨2⟩ et ⟨3⟩un lien⟨4⟩\nLigne deux',
        'Speaker notes.': 'Notes.',
      });
      final slide1 = entryText(output, 'ppt/slides/slide1.xml');
      expect(
        slide1,
        contains(
          '<a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="fr-FR"/>'
          '<a:t>Résultats trimestriels</a:t></a:r>'
          '<a:endParaRPr lang="fr-FR"/></a:p>',
        ),
      );
      expect(
        slide1,
        contains(
          '<a:r><a:rPr lang="fr-FR" b="1"/><a:t>Gras</a:t></a:r>'
          '<a:r><a:rPr lang="fr-FR"/><a:t> et </a:t></a:r>'
          '<a:r><a:rPr lang="fr-FR"><a:hlinkClick r:id="rId2"/></a:rPr>'
          '<a:t>un lien</a:t></a:r>',
        ),
      );
      expect(
        slide1,
        contains(
          '<a:br><a:rPr lang="fr-FR"/></a:br><a:r><a:rPr lang="fr-FR"/>'
          '<a:t>Ligne deux</a:t></a:r>',
        ),
      );
      // The second slide shares the first paragraph's translation.
      final slide2 = entryText(output, 'ppt/slides/slide2.xml');
      expect(slide2, contains('<a:r><a:t>Résultats trimestriels</a:t></a:r>'));
      expect(slide2, contains('<a:t>Slide </a:t>'));
      expect(
        entryText(output, 'ppt/notesSlides/notesSlide1.xml'),
        contains('<a:t>Notes.</a:t>'),
      );
      // Defaults in presentation.xml follow the target language.
      expect(
        entryText(output, 'ppt/presentation.xml'),
        contains('<a:defRPr lang="fr-FR"/>'),
      );
    });

    test('without a target, run languages stay', () {
      final bytes = pptx([
        shape('<a:p><a:r><a:rPr lang="en-US"/><a:t>Hello</a:t></a:r></a:p>'),
      ]);
      final output = parse(bytes, target: null).render(['Bonjour']);
      expect(
        entryText(output, 'ppt/slides/slide1.xml'),
        contains('<a:r><a:rPr lang="en-US"/><a:t>Bonjour</a:t></a:r>'),
      );
      expect(
        entryText(output, 'ppt/presentation.xml'),
        entryText(bytes, 'ppt/presentation.xml'),
      );
    });
  });

  group('XLSX', () {
    PackagedDocument parse(Uint8List bytes) =>
        parsePackagedDocument(bytes, DocumentFormat.xlsx, targetLanguage: 'es');

    test('shared strings, rich text and inline strings', () {
      const rich =
          '<si><r><rPr><b/><sz val="11"/></rPr><t>Total</t></r>'
          '<r><t xml:space="preserve"> amount</t></r></si>';
      const phonetic =
          '<si><t>漢字</t><rPh sb="0" eb="2"><t>かんじ</t></rPh>'
          '<phoneticPr fontId="1"/></si>';
      final bytes = xlsx(
        [
          '<si><t>Name</t></si>',
          '<si><t>12345</t></si>',
          rich,
          '<si><t>Line 1_x000D_\nLine 2 _x005F_x0041_</t></si>',
          phonetic,
          '<si><t/></si>',
        ],
        sheetData:
            '<row r="1"><c r="A1" t="s"><v>0</v></c>'
            '<c r="B1"><v>42</v></c>'
            '<c r="C1" t="str"><f>CONCAT("a","b")</f><v>ab</v></c>'
            '<c r="D1" t="inlineStr"><is><t>Inline note</t></is></c></row>',
      );
      final document = parse(bytes);
      expect(textsOf(document), [
        'Name',
        '⟨1⟩Total⟨2⟩ amount',
        'Line 1\nLine 2 _x0041_',
        '漢字',
        'Inline note',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'es');

      final output = renderWith(document, {
        'Name': 'Nombre',
        '⟨1⟩Total⟨2⟩ amount': '⟨1⟩Importe⟨2⟩ total',
        'Line 1\nLine 2 _x0041_': 'Línea 1\nLínea 2 _x0041_',
        '漢字': 'Kanji',
        'Inline note': 'Nota',
      });
      final strings = entryText(output, 'xl/sharedStrings.xml');
      expect(strings, contains('<si><t xml:space="preserve">Nombre</t></si>'));
      expect(strings, contains('<si><t>12345</t></si>'));
      expect(
        strings,
        contains(
          '<si><r><rPr><b/><sz val="11"/></rPr><t xml:space="preserve">'
          'Importe</t></r><r><t xml:space="preserve"> total</t></r></si>',
        ),
      );
      expect(
        strings,
        contains('<t xml:space="preserve">Línea 1\nLínea 2 _x005F_x0041_</t>'),
      );
      // Phonetic readings of the original are dropped.
      expect(
        strings,
        contains(
          '<si><t xml:space="preserve">Kanji</t><phoneticPr fontId="1"/>'
          '</si>',
        ),
      );
      final sheet = entryText(output, 'xl/worksheets/sheet1.xml');
      expect(sheet, contains('<c r="B1"><v>42</v></c>'));
      expect(sheet, contains('<is><t xml:space="preserve">Nota</t></is>'));
      expect(sheet, contains('<f>CONCAT("a","b")</f><v>ab</v>'));
    });

    test('worksheets are read only for their inline strings', () {
      // Not even parsed without inline strings (this one is malformed).
      final plain = xlsx([
        '<si><t>Name</t></si>',
      ], sheetData: '<row><c r="A1" t="s"><v>0</v></c>');
      expect(textsOf(parse(plain)), ['Name']);

      // Too large to read: the worksheet is left as it is.
      final large = xlsx(
        ['<si><t>Name</t></si>'],
        sheetData:
            '<row r="1"><c r="A1" t="inlineStr"><is><t>Inline</t></is></c>'
            '</row>${'<row/>' * 200}',
      );
      final document = OfficePackage.parse(
        large,
        DocumentFormat.xlsx,
        limits: const PackageLimits(maxPartBytes: 1000),
      );
      expect(textsOf(document), ['Name']);
      expect(textsOf(parse(large)), ['Name', 'Inline']);
    });
  });
}
