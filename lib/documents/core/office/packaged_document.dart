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
/// * Macros and ActiveX controls are the user's own: they are accepted and
///   copied unchanged ([hasMacros] tells).
final class OfficePackage implements PackagedDocument {
  new _({
    required this.format,
    required this._bytes,
    required this._parts,
    required List<Segment> segments,
    required this.language,
    required this.hasMacros,
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
    final (zip, table, readers) = _readers(bytes, format, limits);
    return OfficePackage._(
      format: format,
      bytes: bytes,
      parts: [for (final read in readers) ?read()],
      segments: table.segments,
      language: LanguageTag.tryParse(targetLanguage),
      hasMacros: zip.entries.any((entry) => isMacroPart(entry.name)),
      limits: limits,
    );
  }

  /// Like [OfficePackage.parse], but lets the event loop run between parts
  /// (for the web app, which parses on the UI thread: the page keeps
  /// painting while a book with many chapters is read). One large part
  /// still takes as long as it does.
  static Future<OfficePackage> parseAsync(
    Uint8List bytes,
    DocumentFormat format, {
    String? targetLanguage,
    PackageLimits limits = const PackageLimits(),
  }) async {
    await _yield();
    final (zip, table, readers) = _readers(bytes, format, limits);
    final parts = <PartTemplate>[];
    for (final read in readers) {
      await _yield();
      if (read() case final part?) parts.add(part);
    }
    return OfficePackage._(
      format: format,
      bytes: bytes,
      parts: parts,
      segments: table.segments,
      language: LanguageTag.tryParse(targetLanguage),
      hasMacros: zip.entries.any((entry) => isMacroPart(entry.name)),
      limits: limits,
    );
  }

  static Future<void> _yield() => Future<void>.delayed(Duration.zero);

  static (ZipPackage, SegmentTable, List<PartTemplate? Function()>) _readers(
    Uint8List bytes,
    DocumentFormat format,
    PackageLimits limits,
  ) {
    // PDFs are binary but not packages (lib/documents/pdf/).
    if (!format.isBinary || format == DocumentFormat.pdf) {
      throw ArgumentError.value(format, 'format', 'not a packaged format');
    }
    final zip = ZipPackage.read(bytes, limits: limits);
    final table = SegmentTable();
    final readers = switch (format) {
      DocumentFormat.docx ||
      DocumentFormat.pptx ||
      DocumentFormat.xlsx => ooxmlParts(zip, format, table),
      DocumentFormat.odt ||
      DocumentFormat.odp ||
      DocumentFormat.ods => odfParts(zip, table),
      _ => epubParts(zip, table),
    };
    return (zip, table, readers);
  }

  /// Whether the entry [name] holds macros or ActiveX controls: a VBA
  /// project (`word/vbaProject.bin`), ActiveX controls (`word/activeX/`),
  /// Excel 4 macro sheets (`xl/macrosheets/`), or OpenDocument Basic and
  /// script libraries (`Basic/`, `Scripts/`).
  static bool isMacroPart(String name) {
    final path = '/${name.toLowerCase()}';
    return path.endsWith('/vbaproject.bin') ||
        path.contains('/activex/') ||
        path.contains('/macrosheets/') ||
        path.startsWith('/basic/') ||
        path.startsWith('/scripts/');
  }

  @override
  final DocumentFormat format;
  @override
  final List<Segment> segments;

  /// The language written into translated documents (null: unchanged).
  final LanguageTag? language;

  /// Whether the package holds macros or ActiveX controls (see
  /// [isMacroPart]), which the translated file keeps.
  final bool hasMacros;
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
    hasMacros: hasMacros,
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
      _renderPart(renderer, part, replaced);
    }
    return _write(replaced);
  }

  /// Like [render], but lets the event loop run between parts (see
  /// [parseAsync]).
  Future<Uint8List> renderAsync([List<String?> translations = const []]) async {
    final renderer = PartRenderer(
      translations: translations,
      segments: segments,
      language: language,
    );
    if (!renderer.documentTranslated) return Uint8List.fromList(_bytes);
    final replaced = <String, Uint8List>{};
    for (final part in _parts) {
      await _yield();
      _renderPart(renderer, part, replaced);
    }
    await _yield();
    return _write(replaced);
  }

  void _renderPart(
    PartRenderer renderer,
    PartTemplate part,
    Map<String, Uint8List> replaced,
  ) {
    final changed =
        (part.hasLanguageMarks && language != null) ||
        part.segments.any((index) => renderer.translationOf(index) != null);
    if (!changed) return;
    replaced[part.name] = encodePart(
      renderer.renderPart(part.nodes),
      part.encoding,
    );
  }

  Uint8List _write(Map<String, Uint8List> replaced) {
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
