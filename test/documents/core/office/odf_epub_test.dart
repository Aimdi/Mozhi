// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show CompressionType;
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';

import 'office_fixtures.dart';

void main() {
  group('ODF', () {
    PackagedDocument parse(
      Uint8List bytes,
      DocumentFormat format, {
      String? target = 'de',
    }) => parsePackagedDocument(bytes, format, targetLanguage: target);

    test('text documents: spans, links, spaces, notes and headers', () {
      final bytes = odf(
        'text',
        '<office:text><text:h text:outline-level="1">Title</text:h>'
            '<text:p text:style-name="P1">Hello   '
            '<text:span text:style-name="T1">bold</text:span> and '
            '<text:a xlink:href="https://example.com">a link</text:a>.'
            '<text:s text:c="2"/>Two spaces<text:tab/>tab'
            '<text:line-break/>next line'
            '<text:note text:id="n1" text:note-class="footnote">'
            '<text:note-citation>1</text:note-citation><text:note-body>'
            '<text:p>The note.</text:p></text:note-body></text:note>'
            '<text:soft-page-break/></text:p>'
            '<text:p><text:s text:c="4"/>Indented</text:p>'
            '<text:p/><text:p>  </text:p>'
            '<text:list><text:list-item><text:p>Item</text:p></text:list-item>'
            '</text:list></office:text>',
        masterStyles:
            '<style:master-page style:name="Standard"><style:header>'
            '<text:p>Page header</text:p></style:header></style:master-page>',
      );
      final document = parse(bytes, DocumentFormat.odt);
      expect(textsOf(document), [
        'Title',
        'Hello ⟨1⟩bold⟨2⟩ and ⟨3⟩a link⟨4⟩.  Two spaces⟨5⟩tab\nnext line',
        'The note.',
        'Indented',
        'Item',
        'Page header',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'de');

      final output = renderWith(document, {
        'Title': 'Titel',
        'Hello ⟨1⟩bold⟨2⟩ and ⟨3⟩a link⟨4⟩.  Two spaces⟨5⟩tab\n'
                'next line':
            'Hallo ⟨1⟩fett⟨2⟩ und ⟨3⟩ein Link⟨4⟩.  Zwei⟨5⟩Tab\n'
                'nächste Zeile',
        'The note.': 'Die Notiz.',
        'Indented': 'Eingerückt',
        'Page header': 'Kopfzeile',
      });
      final content = entryText(output, 'content.xml');
      expect(
        content,
        contains(
          '<text:p text:style-name="P1">Hallo '
          '<text:span text:style-name="T1">fett</text:span> und '
          '<text:a xlink:href="https://example.com">ein Link</text:a>.'
          ' <text:s/>Zwei<text:tab/>Tab<text:line-break/>nächste Zeile'
          '<text:note text:id="n1" text:note-class="footnote">'
          '<text:note-citation>1</text:note-citation><text:note-body>'
          '<text:p>Die Notiz.</text:p></text:note-body></text:note>'
          '</text:p>',
        ),
      );
      expect(content, contains('<text:p><text:s text:c="4"/>Eingerückt'));
      expect(content, contains('<text:p>Item</text:p>'));
      // Languages: automatic styles, default styles and meta.xml.
      expect(content, contains('fo:language="de" fo:country="DE"'));
      final styles = entryText(output, 'styles.xml');
      expect(styles, contains('<text:p>Kopfzeile</text:p>'));
      expect(
        styles,
        contains(
          'fo:language="de" fo:country="DE" style:language-asian="zh" '
          'style:country-asian="CN"',
        ),
      );
      expect(
        entryText(output, 'meta.xml'),
        contains('<dc:language>de-DE</dc:language>'),
      );
      // mimetype stays the first entry, stored.
      final first = entriesOf(output).first;
      expect(first.name, 'mimetype');
      expect(first.compression, CompressionType.none);
      expect(
        utf8.decode(first.readBytes()!),
        'application/vnd.oasis.opendocument.text',
      );
    });

    test('mimetype is moved first when it was not', () {
      final bytes = odf(
        'text',
        '<office:text><text:p>Hello</text:p></office:text>',
        mimetypeFirst: false,
      );
      final document = parse(bytes, DocumentFormat.odt);
      final output = document.render(['Hallo']);
      final entries = entriesOf(output);
      expect(entries.first.name, 'mimetype');
      expect(entries.first.compression, CompressionType.none);
      // The raw bytes: no extra field, sizes in the local header.
      expect(output.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);
      expect(output[6] & 0x08, 0, reason: 'no data descriptor');
      expect(output[28] | output[29] << 8, 0, reason: 'no extra field');
      expect(ascii.decode(output.sublist(30, 38)), 'mimetype');
    });

    test('presentations: frames and notes; master pages are kept', () {
      final bytes = odf(
        'presentation',
        '<office:presentation><draw:page draw:name="p1"><draw:frame>'
            '<draw:text-box><text:p>Slide title</text:p></draw:text-box>'
            '</draw:frame><presentation:notes><draw:frame><draw:text-box>'
            '<text:p>Notes here</text:p></draw:text-box></draw:frame>'
            '</presentation:notes></draw:page></office:presentation>',
        masterStyles:
            '<style:master-page style:name="M"><draw:frame><draw:text-box>'
            '<text:p>Click to edit</text:p></draw:text-box></draw:frame>'
            '</style:master-page>',
      );
      final document = parse(bytes, DocumentFormat.odp);
      expect(textsOf(document), ['Slide title', 'Notes here']);
      expectRoundTrip(document, bytes, targetLanguage: 'de');
    });

    test('spreadsheets: text cells only', () {
      final bytes = odf(
        'spreadsheet',
        '<office:spreadsheet><table:table table:name="Sheet1"><table:table-row>'
            '<table:table-cell office:value-type="string"><text:p>Product'
            '</text:p></table:table-cell>'
            '<table:table-cell office:value-type="float" office:value="3">'
            '<text:p>3</text:p></table:table-cell>'
            '<table:table-cell office:value-type="date" '
            'office:date-value="2024-01-05"><text:p>Jan 5, 2024</text:p>'
            '</table:table-cell>'
            '<table:table-cell table:formula="of:=A1" '
            'office:value-type="string"><text:p>Product</text:p>'
            '</table:table-cell>'
            '<table:table-cell><text:p>Comment</text:p></table:table-cell>'
            '</table:table-row></table:table></office:spreadsheet>',
      );
      final document = parse(bytes, DocumentFormat.ods);
      expect(textsOf(document), ['Product', 'Comment']);
      final content = entryText(
        renderWith(document, {'Product': 'Produkt'}),
        'content.xml',
      );
      expect(content, contains('<text:p>Produkt</text:p>'));
      expect(content, contains('<text:p>Jan 5, 2024</text:p>'));
      // The formula's cached result stays.
      expect(
        content,
        contains(
          'table:formula="of:=A1" office:value-type="string">'
          '<text:p>Product</text:p>',
        ),
      );
    });

    test('password-protected documents are refused', () {
      final bytes = odf(
        'text',
        '<office:text><text:p>Secret</text:p></office:text>',
        manifestExtra:
            '<manifest:encryption-data manifest:checksum-type="SHA1"/>',
      );
      expect(
        () => parse(bytes, DocumentFormat.odt),
        throwsA(
          isA<PackageParseException>().having(
            (e) => e.problem,
            'problem',
            PackageProblem.encrypted,
          ),
        ),
      );
    });

    test('packages without content are not OpenDocument files', () {
      expect(
        () => parse(zipOf({'mimetype': 'text/plain'}), DocumentFormat.odt),
        throwsA(isA<PackageParseException>()),
      );
      // Without a mimetype entry the manifest names the type.
      final bytes = zipOf({
        'META-INF/manifest.xml':
            '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:'
            'opendocument:xmlns:manifest:1.0"><manifest:file-entry '
            'manifest:full-path="/" manifest:media-type="application/'
            'vnd.oasis.opendocument.text"/></manifest:manifest>',
        'content.xml':
            '<office:document-content $odfNamespaces><office:body>'
            '<office:text><text:p>Hi there</text:p></office:text>'
            '</office:body></office:document-content>',
      });
      final document = parse(bytes, DocumentFormat.odt);
      expect(textsOf(document), ['Hi there']);
      expect(
        entriesOf(document.render(['Hallo'])).first.name,
        isNot('mimetype'),
      );
    });
  });

  group('EPUB', () {
    PackagedDocument parse(Uint8List bytes, {String? target = 'fr'}) =>
        parsePackagedDocument(
          bytes,
          DocumentFormat.epub,
          targetLanguage: target,
        );

    test('spine documents, blocks, inline markup and the title', () {
      final bytes = epub({
        'chapter 1.xhtml':
            '<h1 class="c">Chapter&nbsp;One</h1>\n'
            '  <p>It was a <em>dark</em> and\n   stormy night.<br/>'
            'Really <a href="#n1" epub:type="noteref">1</a>.</p>\n'
            '<ul><li>First <b>item</b></li><li>Second item'
            '<ul><li>Nested</li></ul></li></ul>'
            '<p>An image <img src="a.png" alt="A"/> here, '
            '<code>x = 1</code>.</p>'
            '<pre>  keep   this  </pre><script>var a = "b";</script>'
            '<div>Loose text<p>Inner paragraph</p>tail text</div>'
            '<table><tr><td>Cell</td><td>42</td></tr></table>',
        'ch2.xhtml': '<section><p>Second chapter.</p></section>',
      });
      final document = parse(bytes);
      expect(textsOf(document), [
        'A Tale',
        'chapter 1.xhtml',
        'Chapter One',
        'It was a ⟨1⟩dark⟨2⟩ and stormy night.\nReally ⟨3⟩1⟨4⟩.',
        'First ⟨1⟩item⟨2⟩',
        'Second item',
        'Nested',
        'An image ⟨1⟩ here, ⟨2⟩.',
        'Loose text',
        'Inner paragraph',
        'tail text',
        'Cell',
        'ch2.xhtml',
        'Second chapter.',
      ]);
      expectRoundTrip(document, bytes, targetLanguage: 'fr');

      final output = renderWith(document, {
        'A Tale': 'Un conte',
        'It was a ⟨1⟩dark⟨2⟩ and stormy night.\nReally ⟨3⟩1⟨4⟩.':
            "C'était une nuit ⟨1⟩sombre⟨2⟩ & orageuse.\nVraiment ⟨3⟩1⟨4⟩.",
        'An image ⟨1⟩ here, ⟨2⟩.': 'Une image ⟨1⟩ ici, ⟨2⟩.',
        'Second chapter.': 'Deuxième chapitre.',
      });
      final chapter = entryText(output, 'OEBPS/chapter 1.xhtml');
      expect(
        chapter,
        contains(
          "<p>C'était une nuit <em>sombre</em> &amp; orageuse.<br/>"
          'Vraiment <a href="#n1" epub:type="noteref">1</a>.</p>',
        ),
      );
      expect(
        chapter,
        contains(
          '<p>Une image <img src="a.png" alt="A"/> ici, '
          '<code>x = 1</code>.</p>',
        ),
      );
      expect(chapter, contains('<pre>  keep   this  </pre>'));
      expect(chapter, contains('<h1 class="c">Chapter&nbsp;One</h1>'));
      expect(chapter, contains('lang="fr" xml:lang="fr"'));
      expect(chapter, startsWith('<?xml version="1.0" encoding="UTF-8"?>\n'));
      final opf = entryText(output, 'OEBPS/content.opf');
      expect(opf, contains('<dc:title>Un conte</dc:title>'));
      expect(opf, contains('<dc:language>fr</dc:language>'));
      expect(entriesOf(output).first.name, 'mimetype');
      expect(entriesOf(output).first.compression, CompressionType.none);
    });

    test('the NCX table of contents and EPUB 2 doctypes', () {
      final bytes = epub(
        {'c.xhtml': '<p>Body text</p>'},
        doctype:
            '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
            '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n',
        ncx:
            '<?xml version="1.0"?>\n<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx '
            '2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">\n'
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            '<docTitle><text>A Tale</text></docTitle><navMap>'
            '<navPoint id="n"><navLabel><text>Start  here</text></navLabel>'
            '<content src="c.xhtml"/></navPoint></navMap></ncx>',
      );
      final document = parse(bytes);
      expect(textsOf(document), [
        'A Tale',
        'c.xhtml',
        'Body text',
        'Start here',
      ]);
      final output = renderWith(document, {
        'A Tale': 'Un conte',
        'Start here': 'Commencer ici',
      });
      final ncx = entryText(output, 'OEBPS/toc.ncx');
      expect(ncx, contains('<docTitle><text>Un conte</text></docTitle>'));
      expect(ncx, contains('<navLabel><text>Commencer ici</text></navLabel>'));
    });

    test('documents without a language get one', () {
      final bytes = zipOf({
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml':
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:'
            'container"><rootfiles><rootfile full-path="book.opf"/>'
            '</rootfiles></container>',
        'book.opf':
            '<package xmlns="http://www.idpf.org/2007/opf"><manifest>'
            '<item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="nav" href="nav.xhtml" properties="nav" '
            'media-type="application/xhtml+xml"/>'
            '<item id="out" href="../out.xhtml" '
            'media-type="application/xhtml+xml"/>'
            '</manifest><spine><itemref idref="a"/><itemref idref="out"/>'
            '<itemref idref="a"/></spine></package>',
        'a.xhtml': '<html xmlns="$xhtmlNs"><body><p>Words</p></body></html>',
        'nav.xhtml':
            '<html xmlns="$xhtmlNs"><body><nav><ol><li>Contents</li></ol>'
            '</nav></body></html>',
      });
      final document = parse(bytes);
      expect(textsOf(document), ['Words', 'Contents']);
      expect(
        entryText(document.render(['Mots']), 'a.xhtml'),
        '<html xmlns="$xhtmlNs" lang="fr" xml:lang="fr"><body><p>Mots</p>'
        '</body></html>',
      );
    });

    test('books with DRM are refused; obfuscated fonts are fine', () {
      Uint8List withEncryption(String algorithm) => epub(
        {'c.xhtml': '<p>Text</p>'},
        extra: {
          'META-INF/encryption.xml':
              '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:'
              'container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
              '<enc:EncryptedData><enc:EncryptionMethod '
              'Algorithm="$algorithm"/><enc:CipherData><enc:CipherReference '
              'URI="OEBPS/c.xhtml"/></enc:CipherData></enc:EncryptedData>'
              '</encryption>',
        },
      );
      expect(
        textsOf(parse(withEncryption('http://www.idpf.org/2008/embedding'))),
        contains('Text'),
      );
      expect(
        () => parse(
          withEncryption('http://www.w3.org/2001/04/xmlenc#aes128-cbc'),
        ),
        throwsA(
          isA<PackageParseException>().having(
            (e) => e.problem,
            'problem',
            PackageProblem.encrypted,
          ),
        ),
      );
      expect(
        () => parse(
          epub({'c.xhtml': '<p>x</p>'}, extra: {'META-INF/rights.xml': '<r/>'}),
        ),
        throwsA(isA<PackageParseException>()),
      );
      expect(
        () => parse(zipOf({'mimetype': 'application/epub+zip'})),
        throwsA(
          isA<PackageParseException>().having(
            (e) => e.problem,
            'problem',
            PackageProblem.damaged,
          ),
        ),
      );
    });
  });
}
