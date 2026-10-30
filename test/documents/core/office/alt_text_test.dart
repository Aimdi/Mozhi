// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings, lines_longer_than_80_chars

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';

import 'office_fixtures.dart';

const _wpNs =
    'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
const _picNs = 'http://schemas.openxmlformats.org/drawingml/2006/picture';
const _p = 'application/vnd.openxmlformats-officedocument.presentationml';

/// A picture in a Word run whose `wp:docPr` has [docPr] attributes; the
/// picture's own `pic:cNvPr` repeats the description.
String _picture(String docPr, {String description = ''}) =>
    '<w:r><w:drawing><wp:inline xmlns:wp="$_wpNs" xmlns:a="$aNs" '
    'xmlns:pic="$_picNs"><wp:extent cx="10" cy="10"/>'
    '<wp:docPr $docPr/><a:graphic><a:graphicData '
    'uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
    '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="bike.png"$description/>'
    '<pic:cNvPicPr/></pic:nvPicPr><pic:blipFill/><pic:spPr/></pic:pic>'
    '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';

void main() {
  group('DOCX alternative text', () {
    test('descr and title of pictures are translated in place', () {
      final bytes = docx(
        '<w:p>${_picture('id="1" name="Picture 1" descr="A red bicycle&#xA;by a wall" title="Bicycle"', description: ' descr="A red bicycle&#xA;by a wall"')}</w:p>'
        '<w:p><w:r><w:t xml:space="preserve">See </w:t></w:r>'
        '${_picture("id='2' name='Chart 2' descr='Sales &amp; costs'")}'
        '<w:r><w:t xml:space="preserve"> below.</w:t></w:r></w:p>'
        '<w:p>${_picture('id="3" name="Picture 3" descr="12345"')}</w:p>',
        header: '<w:p><w:r><w:t>Header</w:t></w:r></w:p>',
      );
      final document = parsePackagedDocument(
        bytes,
        DocumentFormat.docx,
        targetLanguage: 'es',
      );
      expect(textsOf(document), [
        'A red bicycle\nby a wall',
        'Bicycle',
        'See ⟨1⟩ below.',
        'Sales & costs',
        'Header',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'es');

      final output = renderWith(document, {
        'A red bicycle\nby a wall': 'Una bicicleta roja\njunto a una pared',
        'Bicycle': 'Bicicleta',
        'Sales & costs': "Ventas y 'costes'",
      });
      final body = entryText(output, 'word/document.xml');
      expect(
        body,
        contains(
          '<wp:docPr id="1" name="Picture 1" descr="Una bicicleta roja&#xA;'
          'junto a una pared" title="Bicicleta"/>',
        ),
      );
      expect(
        body,
        contains(
          '<pic:cNvPr id="0" name="bike.png" descr="Una bicicleta roja&#xA;'
          'junto a una pared"/>',
        ),
      );
      // The paragraph around the chart is not translated; its picture is.
      expect(body, contains('<w:t xml:space="preserve">See </w:t>'));
      expect(
        body,
        contains(
          "<wp:docPr id='2' name='Chart 2' descr='Ventas y &apos;costes&apos;'/>",
        ),
      );
      expect(body, contains('descr="12345"'));
      // The header and the image are copied as they were.
      expect(
        entryText(output, 'word/header1.xml'),
        entryText(bytes, 'word/header1.xml'),
      );
      expect(
        entriesOf(output)
            .firstWhere((entry) => entry.name == 'word/media/image1.png')
            .readBytes(),
        entriesOf(bytes)
            .firstWhere((entry) => entry.name == 'word/media/image1.png')
            .readBytes(),
      );

      // With the paragraph translated too, the picture keeps its new text.
      final both = renderWith(document, {
        'See ⟨1⟩ below.': 'Ver ⟨1⟩ abajo.',
        'Sales & costs': 'Ventas',
      });
      final text = entryText(both, 'word/document.xml');
      expect(text, contains('<w:t xml:space="preserve">Ver </w:t>'));
      expect(text, contains("descr='Ventas'"));
    });

    test('styles and settings do not translate alternative text', () {
      final bytes = docx(
        '<w:p><w:r><w:t>Body</w:t></w:r></w:p>',
        styles: '<w:style><w:name w:val="Normal"/></w:style>',
      );
      final document = parsePackagedDocument(bytes, DocumentFormat.docx);
      expect(textsOf(document), ['Body']);
    });
  });

  group('PPTX alternative text, masters and comments', () {
    String types(Map<String, String> overrides) =>
        '$declaration<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '${[for (final MapEntry(:key, :value) in overrides.entries) '<Override PartName="/$key" ContentType="$value"/>'].join()}'
        '</Types>';
    String placeholder(String type, String text) =>
        '<p:sp><p:nvSpPr><p:cNvPr id="2" name="$type"/><p:cNvSpPr/><p:nvPr>'
        '<p:ph type="$type"/></p:nvPr></p:nvSpPr><p:txBody><a:bodyPr/>'
        '<a:p><a:r><a:rPr lang="en-US"/><a:t>$text</a:t></a:r></a:p>'
        '</p:txBody></p:sp>';
    String textBox(String text) =>
        '<p:sp><p:nvSpPr><p:cNvPr id="5" name="TextBox 4"/><p:cNvSpPr '
        'txBox="1"/><p:nvPr/></p:nvSpPr><p:txBody><a:bodyPr/><a:p><a:r>'
        '<a:rPr lang="en-US"/><a:t>$text</a:t></a:r></a:p></p:txBody></p:sp>';
    String picture(String description) =>
        '<p:pic><p:nvPicPr><p:cNvPr id="4" name="Picture 3" '
        'descr="$description"><a:hlinkClick r:id="rId2"/></p:cNvPr>'
        '<p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill/><p:spPr/></p:pic>';
    String part(String root, String shapes) =>
        '$declaration<p:$root xmlns:a="$aNs" xmlns:p="$pNs" xmlns:r="$rNs">'
        '<p:cSld><p:spTree>$shapes</p:spTree></p:cSld></p:$root>';

    test('pictures, master shapes and legacy comments', () {
      final bytes = zipOf({
        '[Content_Types].xml': types({
          'ppt/presentation.xml': '$_p.presentation.main+xml',
          'ppt/slideMasters/slideMaster1.xml': '$_p.slideMaster+xml',
          'ppt/slideLayouts/slideLayout1.xml': '$_p.slideLayout+xml',
          'ppt/slides/slide1.xml': '$_p.slide+xml',
          'ppt/comments/comment1.xml': '$_p.comments+xml',
        }),
        'ppt/presentation.xml': '$declaration<p:presentation xmlns:p="$pNs"/>',
        'ppt/slideMasters/slideMaster1.xml': part(
          'sldMaster',
          '${placeholder('title', 'Click to edit Master title style')}'
              '${textBox('Confidential')}${picture('Company logo')}',
        ),
        'ppt/slideLayouts/slideLayout1.xml': part(
          'sldLayout',
          placeholder('body', 'Click to add your agenda'),
        ),
        'ppt/slides/slide1.xml': part(
          'sld',
          '${placeholder('title', 'Welcome')}${picture('Company logo')}',
        ),
        'ppt/comments/comment1.xml':
            '$declaration<p:cmLst xmlns:p="$pNs"><p:cm authorId="0" '
            'dt="2026-01-01T00:00:00" idx="1"><p:pos x="10" y="10"/>'
            '<p:text>Check this figure</p:text></p:cm></p:cmLst>',
      });
      final document = parsePackagedDocument(
        bytes,
        DocumentFormat.pptx,
        targetLanguage: 'fr',
      );
      expect(textsOf(document), [
        'Confidential',
        'Company logo',
        'Welcome',
        'Check this figure',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'fr');

      final output = renderWith(document, {
        'Confidential': 'Confidentiel',
        'Company logo': "Logo de l'entreprise",
        'Welcome': 'Bienvenue',
        'Check this figure': 'Vérifier ce chiffre',
      });
      final master = entryText(output, 'ppt/slideMasters/slideMaster1.xml');
      // Prompts stay; their language follows the document.
      expect(
        master,
        contains(
          '<a:rPr lang="fr-FR"/><a:t>Click to edit Master title style</a:t>',
        ),
      );
      expect(master, contains('<a:t>Confidentiel</a:t>'));
      expect(
        master,
        contains(
          '<p:cNvPr id="4" name="Picture 3" descr="Logo de l\'entreprise">'
          '<a:hlinkClick r:id="rId2"/></p:cNvPr>',
        ),
      );
      expect(
        entryText(output, 'ppt/slideLayouts/slideLayout1.xml'),
        contains('<a:t>Click to add your agenda</a:t>'),
      );
      final slide = entryText(output, 'ppt/slides/slide1.xml');
      expect(slide, contains('<a:t>Bienvenue</a:t>'));
      expect(slide, contains('descr="Logo de l\'entreprise"'));
      expect(
        entryText(output, 'ppt/comments/comment1.xml'),
        contains('<p:text>Vérifier ce chiffre</p:text>'),
      );
    });
  });
}
