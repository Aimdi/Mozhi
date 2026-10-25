import 'package:archive/archive.dart' show ArchiveFile;
import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/office/drawing_parts.dart';
import 'package:mozhi/documents/core/office/epub_parts.dart';
import 'package:mozhi/documents/core/office/package_errors.dart';
import 'package:mozhi/documents/core/office/part_reader.dart';
import 'package:mozhi/documents/core/office/part_template.dart';
import 'package:mozhi/documents/core/office/sheet_parts.dart';
import 'package:mozhi/documents/core/office/word_parts.dart';
import 'package:mozhi/documents/core/office/xml_source.dart';
import 'package:mozhi/documents/core/office/zip_package.dart';

const _officeDocument = 'application/vnd.openxmlformats-officedocument.';
const _word = '${_officeDocument}wordprocessingml.';
const _presentation = '${_officeDocument}presentationml.';
const _spreadsheet = '${_officeDocument}spreadsheetml.';

/// Main parts that make a package a document of each format.
const Map<DocumentFormat, Set<String>> _mainParts = {
  DocumentFormat.docx: {
    '${_word}document.main+xml',
    '${_word}template.main+xml',
    'application/vnd.ms-word.document.macroEnabled.main+xml',
    'application/vnd.ms-word.template.macroEnabledTemplate.main+xml',
  },
  DocumentFormat.pptx: {
    '${_presentation}presentation.main+xml',
    '${_presentation}slideshow.main+xml',
    '${_presentation}template.main+xml',
    'application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml',
    'application/vnd.ms-powerpoint.slideshow.macroEnabled.main+xml',
    'application/vnd.ms-powerpoint.template.macroEnabled.main+xml',
  },
  DocumentFormat.xlsx: {
    '${_spreadsheet}sheet.main+xml',
    '${_spreadsheet}template.main+xml',
    'application/vnd.ms-excel.sheet.macroEnabled.main+xml',
    'application/vnd.ms-excel.template.macroEnabled.main+xml',
  },
};

/// Parts whose text is translated, by content type, and how.
final Map<String, PartBuilderFactory> _translated = {
  for (final type in [..._mainParts[DocumentFormat.docx]!])
    type: WordPartBuilder.new,
  for (final kind in ['header', 'footer', 'footnotes', 'endnotes', 'comments'])
    '$_word$kind+xml': WordPartBuilder.new,
  '${_presentation}slide+xml': DrawingPartBuilder.new,
  '${_presentation}notesSlide+xml': DrawingPartBuilder.new,
  'application/vnd.ms-powerpoint.comments+xml': DrawingPartBuilder.new,
  '${_spreadsheet}sharedStrings+xml': SheetPartBuilder.new,
  '${_spreadsheet}worksheet+xml': SheetPartBuilder.new,
  '${_officeDocument}drawingml.chart+xml': DrawingPartBuilder.new,
  '${_officeDocument}drawingml.diagramData+xml': DrawingPartBuilder.new,
  'application/vnd.ms-office.drawingml.diagramDrawing+xml':
      DrawingPartBuilder.new,
  '${_officeDocument}drawing+xml': DrawingPartBuilder.new,
};

/// Parts that only record languages (document defaults, masters).
final Map<String, PartBuilderFactory> _languageOnly = {
  '${_word}styles+xml': (document, table) =>
      WordPartBuilder(document, table, translate: false),
  '${_word}settings+xml': (document, table) =>
      WordPartBuilder(document, table, translate: false),
  for (final type in _mainParts[DocumentFormat.pptx]!)
    type: (document, table) =>
        DrawingPartBuilder(document, table, translate: false),
  for (final kind in ['slideMaster', 'slideLayout', 'notesMaster'])
    '$_presentation$kind+xml': (document, table) =>
        DrawingPartBuilder(document, table, translate: false),
  'application/vnd.openxmlformats-package.core-properties+xml':
      (document, table) => PlainTextPartBuilder(
        document,
        table,
        paragraphs: (_) => false,
        languages: (element) => element.isA(Ns.dublinCore, 'language'),
        languageKind: LanguageMarkKind.elementCulture,
      ),
};

/// The parts of an Office Open XML package ([format] docx, pptx or xlsx),
/// found through `[Content_Types].xml`.
List<PartTemplate> ooxmlParts(
  ZipPackage zip,
  DocumentFormat format,
  SegmentTable table,
) {
  final types = zip.file('[Content_Types].xml');
  if (types == null) {
    throw const PackageParseException(
      PackageProblem.damaged,
      'not an Office Open XML package',
    );
  }
  final typeDocument = readXml(zip, types);
  final defaults = <String, String>{};
  final overrides = <String, String>{};
  for (final element in typeDocument.root.elements) {
    if (!element.inNamespace(Ns.contentTypes)) continue;
    final type = element.attribute('ContentType')?.trim();
    if (type == null) continue;
    if (element.localName == 'Default') {
      final extension = element.attribute('Extension');
      if (extension != null) defaults[extension.toLowerCase()] = type;
    } else if (element.localName == 'Override') {
      final name = element.attribute('PartName');
      if (name != null) overrides[_partName(name)] = type;
    }
  }
  String? typeOf(ArchiveFile entry) {
    final name = entry.name.toLowerCase();
    final override = overrides[name];
    if (override != null) return override;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? null : defaults[name.substring(dot + 1)];
  }

  final main = _mainParts[format]!;
  if (!zip.entries.any((entry) => main.contains(typeOf(entry)))) {
    throw PackageParseException(
      PackageProblem.damaged,
      'not a ${format.defaultExtension.toUpperCase()} document',
    );
  }

  return [
    for (final entry in zip.entries)
      if (entry.isFile)
        if (typeOf(entry) case final type?)
          if (_translated[type] ?? _languageOnly[type] case final builder?)
            readPart(zip, entry, table, builder),
  ];
}

/// A part name from `[Content_Types].xml` as an entry name: without the
/// leading slash, percent-decoded, lower case.
String _partName(String name) {
  final value = name.startsWith('/') ? name.substring(1) : name;
  return decodePercents(value).toLowerCase();
}

final _percent = RegExp('%(?![0-9A-Fa-f]{2})');

/// [value] with percent escapes decoded (kept as written when they are
/// malformed).
String decodePercents(String value) {
  if (!value.contains('%') || _percent.hasMatch(value)) return value;
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}
