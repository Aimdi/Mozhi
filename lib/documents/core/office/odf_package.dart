import 'dart:convert';

import 'package:mozhi/documents/core/office/odf_parts.dart';
import 'package:mozhi/documents/core/office/package_errors.dart';
import 'package:mozhi/documents/core/office/part_reader.dart';
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:mozhi/documents/core/office/zip_package.dart';

const _odfPrefix = 'application/vnd.oasis.opendocument.';

/// The parts of an OpenDocument package: `content.xml`, the headers and
/// footers of `styles.xml` (not for presentations, whose master pages hold
/// placeholder prompts) and the language in `meta.xml`.
///
/// Refuses encrypted documents (`manifest:encryption-data`). Each part is
/// read when its function is called.
List<PartTemplate Function()> odfParts(ZipPackage zip, SegmentTable table) {
  final manifestEntry = zip.file('META-INF/manifest.xml');
  final manifest = manifestEntry == null ? null : readXml(zip, manifestEntry);
  if (manifest != null &&
      manifest.root.descendants.any(
        (element) => element.isA(Ns.odfManifest, 'encryption-data'),
      )) {
    throw const PackageParseException(
      PackageProblem.encrypted,
      'a password-protected OpenDocument file',
    );
  }

  final mimetypeEntry = zip.file('mimetype');
  var mimetype = mimetypeEntry == null
      ? null
      : latin1.decode(zip.readBytes(mimetypeEntry)).trim();
  if (mimetype == null && manifest != null) {
    for (final entry in manifest.root.descendants) {
      if (entry.isA(Ns.odfManifest, 'file-entry') &&
          entry.attribute('full-path', Ns.odfManifest) == '/') {
        mimetype = entry.attribute('media-type', Ns.odfManifest);
      }
    }
  }
  final content = zip.file('content.xml');
  if (mimetype == null || !mimetype.startsWith(_odfPrefix) || content == null) {
    throw const PackageParseException(
      PackageProblem.damaged,
      'not an OpenDocument package',
    );
  }
  final presentation = mimetype.contains('presentation');

  return [
    () => readPart(zip, content, table, OdfPartBuilder.new),
    if (zip.file('styles.xml') case final styles?)
      () => readPart(
        zip,
        styles,
        table,
        (document, table) => OdfPartBuilder(
          document,
          table,
          translate: !presentation,
          mastersOnly: true,
        ),
      ),
    if (zip.file('meta.xml') case final meta?)
      () => readPart(
        zip,
        meta,
        table,
        (document, table) => OdfPartBuilder(document, table, translate: false),
      ),
  ];
}
