// XML fixtures are written as adjacent string literals.
// ignore_for_file: missing_whitespace_between_adjacent_strings, lines_longer_than_80_chars

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/documents/core/office/office.dart';
import 'package:xml/xml.dart';

const wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const rNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const aNs = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const pNs = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const sNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const declaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

const _office = 'application/vnd.openxmlformats-officedocument';

/// A ZIP package of [files] (text or bytes), in order; [stored] entries are
/// not compressed.
Uint8List zipOf(
  Map<String, Object> files, {
  Set<String> stored = const {},
  int level = DeflateLevel.bestSpeed,
}) {
  final archive = Archive();
  for (final MapEntry(key: name, value: content) in files.entries) {
    final bytes = content is String
        ? utf8.encode(content)
        : content as List<int>;
    final file = stored.contains(name)
        ? ArchiveFile.noCompress(name, bytes.length, bytes)
        : ArchiveFile.bytes(name, bytes);
    archive.add(file);
  }
  return ZipEncoder().encodeBytes(archive, level: level);
}

String _types(Map<String, String> overrides) =>
    '$declaration<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Default Extension="png" ContentType="image/png"/>'
    '${[for (final MapEntry(:key, :value) in overrides.entries) '<Override PartName="/$key" ContentType="$value"/>'].join()}'
    '</Types>';

String _rels(Map<String, String> targets) =>
    '$declaration<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '${[for (final (i, MapEntry(:key, :value)) in targets.entries.indexed) '<Relationship Id="rId${i + 1}" Type="$value" Target="$key"/>'].join()}'
    '</Relationships>';

/// The core properties part with [language].
String coreXml(String language) =>
    '$declaration<cp:coreProperties '
    'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>Report</dc:title><dc:language>$language</dc:language>'
    '</cp:coreProperties>';

/// A Word document whose body is [body] (paragraph XML using the `w:` and
/// `r:` prefixes).
Uint8List docx(
  String body, {
  String? header,
  String? footnotes,
  String? styles,
  String? language = 'en-US',
  Map<String, Object> extra = const {},
  bool imageStored = false,
}) {
  const w = '$_office.wordprocessingml';
  return zipOf({
    '[Content_Types].xml': _types({
      'word/document.xml': '$w.document.main+xml',
      if (styles != null) 'word/styles.xml': '$w.styles+xml',
      if (header != null) 'word/header1.xml': '$w.header+xml',
      if (footnotes != null) 'word/footnotes.xml': '$w.footnotes+xml',
      if (language != null)
        'docProps/core.xml':
            'application/vnd.openxmlformats-package.core-properties+xml',
    }),
    '_rels/.rels': _rels({'word/document.xml': '$rNs/officeDocument'}),
    'word/document.xml':
        '$declaration<w:document xmlns:w="$wNs" xmlns:r="$rNs">'
        '<w:body>$body<w:sectPr/></w:body></w:document>',
    'word/_rels/document.xml.rels': _rels({
      'styles.xml': '$rNs/styles',
      'https://example.com/': '$rNs/hyperlink',
    }),
    if (styles != null)
      'word/styles.xml':
          '$declaration<w:styles xmlns:w="$wNs">$styles</w:styles>',
    if (header != null)
      'word/header1.xml':
          '$declaration<w:hdr xmlns:w="$wNs" xmlns:r="$rNs">$header</w:hdr>',
    if (footnotes != null)
      'word/footnotes.xml':
          '$declaration<w:footnotes xmlns:w="$wNs">$footnotes</w:footnotes>',
    if (language != null) 'docProps/core.xml': coreXml(language),
    'word/media/image1.png': Uint8List.fromList(
      List<int>.generate(300, (i) => (i * 7) % 256),
    ),
    ...extra,
  }, stored: imageStored ? {'word/media/image1.png'} : const {});
}

/// A presentation with one slide per entry of [slides] (each the XML of
/// the slide's shapes) and optional speaker [notes] for the first slide.
Uint8List pptx(List<String> slides, {String? notes}) {
  const p = '$_office.presentationml';
  return zipOf({
    '[Content_Types].xml': _types({
      'ppt/presentation.xml': '$p.presentation.main+xml',
      for (var i = 0; i < slides.length; i++)
        'ppt/slides/slide${i + 1}.xml': '$p.slide+xml',
      if (notes != null) 'ppt/notesSlides/notesSlide1.xml': '$p.notesSlide+xml',
    }),
    '_rels/.rels': _rels({'ppt/presentation.xml': '$rNs/officeDocument'}),
    'ppt/presentation.xml':
        '$declaration<p:presentation xmlns:a="$aNs" xmlns:p="$pNs">'
        '<p:defaultTextStyle><a:lvl1pPr><a:defRPr lang="en-US"/></a:lvl1pPr>'
        '</p:defaultTextStyle></p:presentation>',
    for (var i = 0; i < slides.length; i++)
      'ppt/slides/slide${i + 1}.xml':
          '$declaration<p:sld xmlns:a="$aNs" xmlns:p="$pNs" xmlns:r="$rNs">'
          '<p:cSld><p:spTree>${slides[i]}</p:spTree></p:cSld></p:sld>',
    if (notes != null)
      'ppt/notesSlides/notesSlide1.xml':
          '$declaration<p:notes xmlns:a="$aNs" xmlns:p="$pNs">'
          '<p:cSld><p:spTree>$notes</p:spTree></p:cSld></p:notes>',
  });
}

/// A shape with a text body of [paragraphs] (`a:p` XML).
String shape(String paragraphs) =>
    '<p:sp><p:txBody><a:bodyPr/><a:lstStyle/>$paragraphs</p:txBody></p:sp>';

/// A workbook with [sharedStrings] (`si` XML) and one sheet with
/// [sheetData].
Uint8List xlsx(List<String> sharedStrings, {String sheetData = ''}) {
  const s = '$_office.spreadsheetml';
  return zipOf({
    '[Content_Types].xml': _types({
      'xl/workbook.xml': '$s.sheet.main+xml',
      'xl/worksheets/sheet1.xml': '$s.worksheet+xml',
      'xl/sharedStrings.xml': '$s.sharedStrings+xml',
    }),
    '_rels/.rels': _rels({'xl/workbook.xml': '$rNs/officeDocument'}),
    'xl/workbook.xml':
        '$declaration<workbook xmlns="$sNs" xmlns:r="$rNs"><sheets>'
        '<sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/sharedStrings.xml':
        '$declaration<sst xmlns="$sNs" count="${sharedStrings.length}" '
        'uniqueCount="${sharedStrings.length}">${sharedStrings.join()}</sst>',
    'xl/worksheets/sheet1.xml':
        '$declaration<worksheet xmlns="$sNs"><sheetData>$sheetData'
        '</sheetData></worksheet>',
  });
}

const odfOffice = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0';
const odfNamespaces =
    'xmlns:office="$odfOffice" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
    'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
    'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
    'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
    'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
    'xmlns:xlink="http://www.w3.org/1999/xlink" '
    'xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"';

/// An OpenDocument package of [kind] (`text`, `presentation`,
/// `spreadsheet`) whose `office:body` holds [body].
Uint8List odf(
  String kind,
  String body, {
  String automaticStyles =
      '<style:style style:name="T1" style:family="text">'
      '<style:text-properties fo:font-weight="bold" fo:language="en" '
      'fo:country="US"/></style:style>',
  String? masterStyles,
  String? manifestExtra,
  bool mimetypeFirst = true,
}) {
  final mimetype = 'application/vnd.oasis.opendocument.$kind';
  final files = <String, Object>{
    if (mimetypeFirst) 'mimetype': mimetype,
    'META-INF/manifest.xml':
        '$declaration<manifest:manifest '
        'xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" '
        'manifest:version="1.3">'
        '<manifest:file-entry manifest:full-path="/" '
        'manifest:media-type="$mimetype"/>'
        '<manifest:file-entry manifest:full-path="content.xml" '
        'manifest:media-type="text/xml">${manifestExtra ?? ''}'
        '</manifest:file-entry></manifest:manifest>',
    'content.xml':
        '$declaration<office:document-content $odfNamespaces '
        'office:version="1.3"><office:automatic-styles>$automaticStyles'
        '</office:automatic-styles><office:body>$body</office:body>'
        '</office:document-content>',
    'styles.xml':
        '$declaration<office:document-styles $odfNamespaces '
        'office:version="1.3"><office:styles><style:default-style '
        'style:family="paragraph"><style:text-properties fo:language="en" '
        'fo:country="US" style:language-asian="zh" style:country-asian="CN"/>'
        '</style:default-style></office:styles>'
        '<office:master-styles>${masterStyles ?? ''}</office:master-styles>'
        '</office:document-styles>',
    'meta.xml':
        '$declaration<office:document-meta $odfNamespaces office:version="1.3">'
        '<office:meta><dc:language>en-US</dc:language></office:meta>'
        '</office:document-meta>',
    if (!mimetypeFirst) 'mimetype': mimetype,
  };
  return zipOf(files, stored: {'mimetype'});
}

const xhtmlNs = 'http://www.w3.org/1999/xhtml';

/// An e-book with [chapters] (file name -> `body` content), in spine
/// order.
Uint8List epub(
  Map<String, String> chapters, {
  String title = 'A Tale',
  String language = 'en',
  Map<String, Object> extra = const {},
  String doctype = '<!DOCTYPE html>\n',
  String? ncx,
}) {
  final names = chapters.keys.toList();
  return zipOf(
    {
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml':
          '$declaration<container version="1.0" '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
          '<rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/></rootfiles></container>',
      'OEBPS/content.opf':
          '$declaration<package xmlns="http://www.idpf.org/2007/opf" '
          'version="3.0" unique-identifier="id"><metadata '
          'xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:identifier id="id">urn:uuid:1</dc:identifier>'
          '<dc:title>$title</dc:title><dc:language>$language</dc:language>'
          '</metadata><manifest>'
          '${[for (final (i, name) in names.indexed) '<item id="c$i" href="${Uri.encodeComponent(name)}" media-type="application/xhtml+xml"/>'].join()}'
          '${ncx == null ? '' : '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'}'
          '<item id="css" href="style.css" media-type="text/css"/>'
          '</manifest><spine>'
          '${[for (var i = 0; i < names.length; i++) '<itemref idref="c$i"/>'].join()}'
          '</spine></package>',
      for (final MapEntry(:key, :value) in chapters.entries)
        'OEBPS/$key':
            '<?xml version="1.0" encoding="UTF-8"?>\n$doctype'
            '<html xmlns="$xhtmlNs" xmlns:epub="http://www.idpf.org/2007/ops" '
            'lang="$language" xml:lang="$language"><head><title>$key</title>'
            '<link rel="stylesheet" href="style.css"/></head><body>$value'
            '</body></html>',
      'OEBPS/style.css': 'p { margin: 0; }',
      'OEBPS/toc.ncx': ?ncx,
      ...extra,
    },
    stored: {'mimetype'},
  );
}

/// The entries of a ZIP package, in order.
List<ArchiveFile> entriesOf(Uint8List bytes) =>
    ZipDecoder().decodeBytes(bytes).files.toList();

/// The text of entry [name] of a package.
String entryText(Uint8List bytes, String name) {
  final entry = ZipDecoder().decodeBytes(bytes).findFile(name);
  expect(entry, isNotNull, reason: 'entry $name');
  return utf8.decode(entry!.readBytes()!);
}

/// Segment texts of [document].
List<String> textsOf(PackagedDocument document) => [
  for (final segment in document.segments) segment.text,
];

/// Asserts the round trip of [document] (parsed from [bytes]): rendering
/// nothing gives the bytes back, and "translating" every segment to upper
/// case gives well-formed parts that parse to the upper-cased segments.
void expectRoundTrip(
  PackagedDocument document,
  Uint8List bytes, {
  String? targetLanguage,
}) {
  expect(document.render(), bytes, reason: 'render() keeps the bytes');
  expect(
    document.render([for (final segment in document.segments) segment.text]),
    bytes,
    reason: 'identity translations keep the bytes',
  );
  final upper = [
    for (final segment in document.segments) segment.text.toUpperCase(),
  ];
  final rendered = document.render(upper);
  for (final entry in entriesOf(rendered)) {
    if (!entry.isFile) continue;
    if (!entry.name.endsWith('.xml') &&
        !entry.name.endsWith('.xhtml') &&
        !entry.name.endsWith('.opf') &&
        !entry.name.endsWith('.rels')) {
      continue;
    }
    final text = utf8.decode(entry.readBytes()!);
    expect(
      () => XmlDocument.parse(text),
      returnsNormally,
      reason: '${entry.name} is well-formed',
    );
  }
  final again = parsePackagedDocument(
    rendered,
    document.format,
    targetLanguage: targetLanguage,
  );
  expect(textsOf(again), upper, reason: 'translated segments read back');
}

/// [document] rendered with [translations] keyed by original segment
/// text.
Uint8List renderWith(
  PackagedDocument document,
  Map<String, String> translations,
) => document.render([
  for (final segment in document.segments) translations[segment.text],
]);
