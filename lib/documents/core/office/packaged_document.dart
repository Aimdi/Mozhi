import 'dart:typed_data';

import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/office/epub_package.dart';
import 'package:mozhi/documents/core/office/language_tags.dart';
import 'package:mozhi/documents/core/office/odf_package.dart';
import 'package:mozhi/documents/core/office/ooxml_package.dart';
import 'package:mozhi/documents/core/office/package_errors.dart';
import 'package:mozhi/documents/core/office/part_reader.dart';
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/zip_package.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException;

/// A ZIP-packaged document (DOCX, PPTX, XLSX, ODT, ODP, ODS, EPUB) split
/// into translatable segments; renders the same format back as bytes.
abstract interface class PackagedDocument {
  DocumentFormat get format;

  /// Same type as text documents; formatting runs are placeholders.
  List<Segment> get segments;
  int get characterCount;
  bool get isEmpty;

  /// The document with [translations] (indexed like [segments]; null or
  /// missing entries keep the original text).
  Uint8List render([List<String?> translations = const []]);
}

/// Throws DocumentParseException for damaged, encrypted or unsafe files
/// (zip bomb, too many entries, path traversal, DTD/external entities).
PackagedDocument parsePackagedDocument(
  Uint8List bytes,
  DocumentFormat format, {
  String? targetLanguage, // written as the document language
}) => OfficePackage.parse(bytes, format, targetLanguage: targetLanguage);

/// The [PackagedDocument] of every packaged format.
///
/// * Segments come from paragraphs (Word, OpenDocument text, slides,
///   notes, text boxes, charts), shared and inline strings (spreadsheets)
///   and the inline content of XHTML blocks (e-books); identical texts are
///   one segment, translated once.
/// * [render] rewrites only the XML parts that hold a translated segment
///   (or record the language); every other entry is copied as it was
///   stored. Without any translation it returns the original bytes.
/// * The target language replaces the document's language where the file
///   records one (Word's `w:lang`, run languages in slides, OpenDocument
///   text properties, `dc:language`, the XHTML `lang`).
final class OfficePackage implements PackagedDocument {
  new _({
    required this.format,
    required this._bytes,
    required this._parts,
    required List<Segment> segments,
    required this.language,
    required this._limits,
  }) : segments = List.unmodifiable(segments);

  /// Parses [bytes] as [format] within [limits]. Throws
  /// [PackageParseException] (a [DocumentParseException]).
  factory parse(
    Uint8List bytes,
    DocumentFormat format, {
    String? targetLanguage,
    PackageLimits limits = const PackageLimits(),
  }) {
    if (!format.isBinary) {
      throw ArgumentError.value(format, 'format', 'not a packaged format');
    }
    final zip = ZipPackage.read(bytes, limits: limits);
    final table = SegmentTable();
    final parts = switch (format) {
      DocumentFormat.docx ||
      DocumentFormat.pptx ||
      DocumentFormat.xlsx => ooxmlParts(zip, format, table),
      DocumentFormat.odt ||
      DocumentFormat.odp ||
      DocumentFormat.ods => odfParts(zip, table),
      _ => epubParts(zip, table),
    };
    return OfficePackage._(
      format: format,
      bytes: bytes,
      parts: parts,
      segments: table.segments,
      language: LanguageTag.tryParse(targetLanguage),
      limits: limits,
    );
  }

  @override
  final DocumentFormat format;
  @override
  final List<Segment> segments;

  /// The language written into translated documents (null: unchanged).
  final LanguageTag? language;
  final Uint8List _bytes;
  final List<PartTemplate> _parts;
  final PackageLimits _limits;

  @override
  int get characterCount =>
      segments.fold(0, (total, segment) => total + segment.text.length);

  @override
  bool get isEmpty => segments.isEmpty;

  /// This document with [targetLanguage] as the language written on
  /// rendering (nothing is parsed again).
  OfficePackage withTargetLanguage(String? targetLanguage) => OfficePackage._(
    format: format,
    bytes: _bytes,
    parts: _parts,
    segments: segments,
    language: LanguageTag.tryParse(targetLanguage),
    limits: _limits,
  );

  @override
  Uint8List render([List<String?> translations = const []]) {
    final renderer = PartRenderer(
      translations: translations,
      segments: segments,
      language: language,
    );
    if (!renderer.documentTranslated) return Uint8List.fromList(_bytes);
    final replaced = <String, Uint8List>{};
    for (final part in _parts) {
      final changed =
          (part.hasLanguageMarks && language != null) ||
          part.segments.any((index) => renderer.translationOf(index) != null);
      if (!changed) continue;
      replaced[part.name] = encodePart(
        renderer.renderPart(part.nodes),
        part.encoding,
      );
    }
    return ZipPackage.read(_bytes, limits: _limits).write(
      replaced,
      mimetypeFirst: switch (format) {
        DocumentFormat.odt ||
        DocumentFormat.odp ||
        DocumentFormat.ods ||
        DocumentFormat.epub => true,
        _ => false,
      },
    );
  }
}

/// [text] (a segment or a translation of one) as a reader sees it: without
/// placeholders.
String segmentPreview(String text) =>
    text.replaceAll(placeholderPattern, '').replaceAll(_doubleSpace, ' ');

final _doubleSpace = RegExp(' {2,}');

/// The text of [segments] for previews: every segment (or its translation,
/// when [translations] has one) without placeholders, separated by blank
/// lines.
String segmentsPreview(
  List<Segment> segments, [
  List<String?> translations = const [],
]) => [
  for (var i = 0; i < segments.length; i++)
    segmentPreview(
      (i < translations.length ? translations[i] : null) ?? segments[i].text,
    ),
].join('\n\n');
