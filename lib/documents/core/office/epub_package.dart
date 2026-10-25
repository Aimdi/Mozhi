import 'package:archive/archive.dart' show ArchiveFile;
import 'package:mozhi/documents/core/office/epub_parts.dart';
import 'package:mozhi/documents/core/office/ooxml_package.dart'
    show decodePercents;
import 'package:mozhi/documents/core/office/package_errors.dart';
import 'package:mozhi/documents/core/office/part_reader.dart';
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:mozhi/documents/core/office/zip_package.dart';
import 'package:xml/xml.dart' show XmlDefaultEntityMapping;

/// Font obfuscation (not DRM): fonts stay as they are.
const _fontObfuscation = {
  'http://www.idpf.org/2008/embedding',
  'http://ns.adobe.com/pdf/enc#RC',
};

/// The parts of an EPUB: the package document (title and language), the
/// XHTML content documents of the spine in reading order, the navigation
/// document and the NCX table of contents.
///
/// Refuses books with DRM (`META-INF/rights.xml`, or encrypted resources
/// other than obfuscated fonts).
List<PartTemplate> epubParts(ZipPackage zip, SegmentTable table) {
  if (zip.file('META-INF/rights.xml') != null) {
    throw const PackageParseException(
      PackageProblem.encrypted,
      'an e-book with DRM',
    );
  }
  if (zip.file('META-INF/encryption.xml') case final encryption?) {
    final document = readXml(zip, encryption, allowDoctype: true);
    for (final method in document.root.descendants) {
      if (!method.isA(Ns.xmlEncryption, 'EncryptionMethod')) continue;
      if (!_fontObfuscation.contains(method.attribute('Algorithm'))) {
        throw const PackageParseException(
          PackageProblem.encrypted,
          'an e-book with DRM',
        );
      }
    }
  }

  final container = zip.file('META-INF/container.xml');
  final rootfile = container == null
      ? null
      : readXml(zip, container, allowDoctype: true).root.descendants
            .where((element) => element.isA(Ns.container, 'rootfile'))
            .map((element) => element.attribute('full-path'))
            .nonNulls
            .firstOrNull;
  final opfEntry = rootfile == null
      ? null
      : _entry(zip, decodePercents(rootfile));
  if (opfEntry == null) {
    throw const PackageParseException(
      PackageProblem.damaged,
      'not an EPUB (no package document)',
    );
  }
  final opfName = opfEntry.name;
  final base = opfName.contains('/')
      ? opfName.substring(0, opfName.lastIndexOf('/') + 1)
      : '';

  final opf = readXml(zip, opfEntry, allowDoctype: true);
  final items = <String, ({String href, String type, String properties})>{};
  final spine = <String>[];
  for (final element in opf.root.descendants) {
    if (!element.inNamespace(Ns.opf)) continue;
    if (element.localName == 'item') {
      final id = element.attribute('id');
      final href = element.attribute('href');
      if (id == null || href == null) continue;
      items[id] = (
        href: href,
        type: element.attribute('media-type') ?? '',
        properties: element.attribute('properties') ?? '',
      );
    } else if (element.localName == 'itemref') {
      final id = element.attribute('idref');
      if (id != null) spine.add(id);
    }
  }

  final seen = <String>{opfName};
  ArchiveFile? item(String id, bool Function(String type) accept) {
    final entry = items[id];
    if (entry == null || !accept(entry.type)) return null;
    final file = _entry(zip, _resolve(base, entry.href));
    return file == null || !seen.add(file.name) ? null : file;
  }

  bool xhtml(String type) =>
      type == 'application/xhtml+xml' || type == 'text/html';
  final html5 = const XmlDefaultEntityMapping.html5();

  return [
    readPart(
      zip,
      opfEntry,
      table,
      (document, table) => PlainTextPartBuilder(
        document,
        table,
        paragraphs: (element) => element.isA(Ns.dublinCore, 'title'),
        languages: (element) => element.isA(Ns.dublinCore, 'language'),
      ),
      allowDoctype: true,
    ),
    for (final id in [
      ...spine,
      for (final MapEntry(:key, :value) in items.entries)
        if (value.properties.split(' ').contains('nav')) key,
    ])
      if (item(id, xhtml) case final file?)
        readPart(
          zip,
          file,
          table,
          XhtmlPartBuilder.new,
          allowDoctype: true,
          entities: html5,
        ),
    for (final id in items.keys)
      if (item(id, (type) => type == 'application/x-dtbncx+xml')
          case final file?)
        readPart(
          zip,
          file,
          table,
          (document, table) => PlainTextPartBuilder(
            document,
            table,
            paragraphs: (element) =>
                element.isA(Ns.ncx, 'text') &&
                (element.parent?.localName == 'navLabel' ||
                    element.parent?.localName == 'docTitle'),
          ),
          allowDoctype: true,
          entities: html5,
        ),
  ];
}

ArchiveFile? _entry(ZipPackage zip, String? name) =>
    name == null ? null : zip.file(name) ?? zip.fileIgnoringCase(name);

/// [href] (relative to the package document in [base]) as an entry name;
/// null when it leaves the package.
String? _resolve(String base, String href) {
  final path = decodePercents(href.split('#').first.split('?').first);
  if (path.isEmpty || path.contains(':')) return null;
  final segments = <String>[];
  for (final segment in '$base$path'.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) return null;
      segments.removeLast();
    } else {
      segments.add(segment);
    }
  }
  return segments.join('/');
}
