import 'package:archive/archive.dart' show ArchiveFile;
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:mozhi/documents/core/office/zip_package.dart';
import 'package:xml/xml.dart' show XmlEntityMapping;

/// The template of one XML part of a package.
final class PartTemplate {
  const new({
    required this.name,
    required this.encoding,
    required this.nodes,
    required this.segments,
    required this.hasLanguageMarks,
  });

  /// The entry name in the package.
  final String name;
  final PartEncoding encoding;
  final List<PartNode> nodes;

  /// The segments that appear in the part.
  final List<int> segments;

  /// Whether the part records languages (rewritten for the target).
  final bool hasLanguageMarks;
}

/// Makes the builder of a part.
typedef PartBuilderFactory =
    PartBuilder Function(SourceDocument document, SegmentTable table);

/// Reads, parses and builds the template of [entry].
PartTemplate readPart(
  ZipPackage zip,
  ArchiveFile entry,
  SegmentTable table,
  PartBuilderFactory builder, {
  bool allowDoctype = false,
  XmlEntityMapping? entities,
}) {
  final (text, encoding) = zip.readText(entry);
  return _build(
    entry,
    text,
    encoding,
    zip,
    table,
    builder,
    allowDoctype: allowDoctype,
    entities: entities,
  );
}

/// Like [readPart] for a part that may be left out: null when it is beyond
/// the limits or its text does not contain [requires].
PartTemplate? readOptionalPart(
  ZipPackage zip,
  ArchiveFile entry,
  SegmentTable table,
  PartBuilderFactory builder, {
  required String requires,
}) {
  if (!zip.canRead(entry)) return null;
  final (text, encoding) = zip.readText(entry);
  if (!text.contains(requires)) return null;
  return _build(entry, text, encoding, zip, table, builder);
}

PartTemplate _build(
  ArchiveFile entry,
  String text,
  PartEncoding encoding,
  ZipPackage zip,
  SegmentTable table,
  PartBuilderFactory builder, {
  bool allowDoctype = false,
  XmlEntityMapping? entities,
}) {
  final document = SourceDocument.parse(
    text,
    part: entry.name,
    allowDoctype: allowDoctype,
    maxDepth: zip.limits.maxDepth,
    entities: entities,
  );
  final segments = table.startPart();
  final nodes = builder(document, table).build();
  return PartTemplate(
    name: entry.name,
    encoding: encoding,
    nodes: nodes,
    segments: segments.toList()..sort(),
    hasLanguageMarks: _hasMarks(nodes),
  );
}

/// Parses [entry] as XML (for package metadata: content types,
/// manifests).
SourceDocument readXml(
  ZipPackage zip,
  ArchiveFile entry, {
  bool allowDoctype = false,
}) {
  final (text, _) = zip.readText(entry);
  return SourceDocument.parse(
    text,
    part: entry.name,
    allowDoctype: allowDoctype,
    maxDepth: zip.limits.maxDepth,
  );
}

bool _hasMarks(List<PartNode> nodes) {
  for (final node in nodes) {
    final found = switch (node) {
      RawXml() => false,
      LanguageMark() => true,
      UntranslatedScope(:final children) => _hasMarks(children),
      ParagraphSlot() =>
        _hasMarks(node.original) ||
            _hasMarks(node.open) ||
            _hasMarks(node.close) ||
            _hasMarks(node.base.style.nodes) ||
            node.lead.any(_itemHasMarks) ||
            node.trail.any(_itemHasMarks) ||
            node.placeholders.any(
              (spec) =>
                  spec.objects.any(_itemHasMarks) ||
                  _hasMarks(spec.switchTo?.style.nodes ?? const []),
            ),
    };
    if (found) return true;
  }
  return false;
}

bool _itemHasMarks(OutItem item) => switch (item) {
  OutText(:final context) => _hasMarks(context.style.nodes),
  OutObject(:final nodes) => _hasMarks(nodes),
};
