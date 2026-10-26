import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/android_strings_parser.dart';
import 'package:mozhi/documents/core/parsers/apple_strings_parser.dart';
import 'package:mozhi/documents/core/parsers/delimited_parser.dart';
import 'package:mozhi/documents/core/parsers/html_parser.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart';
import 'package:mozhi/documents/core/parsers/markdown_parser.dart';
import 'package:mozhi/documents/core/parsers/plain_text_parser.dart';
import 'package:mozhi/documents/core/parsers/po_parser.dart';
import 'package:mozhi/documents/core/parsers/subtitle_parser.dart';
import 'package:mozhi/documents/core/parsers/xcstrings_parser.dart';
import 'package:mozhi/documents/core/parsers/xliff_parser.dart';

/// Parses [text] as [format].
///
/// [targetLanguage] (a BCP 47 code) is written into the formats that record
/// it ([DocumentFormat.usesTargetLanguage]); the others ignore it.
///
/// Throws [DocumentParseException] when [text] is not valid in [format].
/// Binary formats ([DocumentFormat.isBinary]) are not text: they throw an
/// [ArgumentError].
ParsedDocument parseDocument(
  String text,
  DocumentFormat format, {
  String? targetLanguage,
}) => switch (format) {
  DocumentFormat.plainText => parsePlainText(text),
  DocumentFormat.markdown => parseMarkdown(text),
  DocumentFormat.srt || DocumentFormat.vtt => parseSubtitles(text, format),
  DocumentFormat.json => parseJson(text),
  DocumentFormat.html => parseHtml(text, targetLanguage: targetLanguage),
  DocumentFormat.xliff => parseXliff(text, targetLanguage: targetLanguage),
  DocumentFormat.androidStrings => parseAndroidStrings(text),
  DocumentFormat.po => parsePo(text, targetLanguage: targetLanguage),
  DocumentFormat.csv || DocumentFormat.tsv => parseDelimited(text, format),
  DocumentFormat.appleStrings => parseAppleStrings(text),
  DocumentFormat.xcstrings => parseXcstrings(
    text,
    targetLanguage: targetLanguage,
  ),
  DocumentFormat.docx ||
  DocumentFormat.pptx ||
  DocumentFormat.xlsx ||
  DocumentFormat.odt ||
  DocumentFormat.odp ||
  DocumentFormat.ods ||
  DocumentFormat.epub ||
  DocumentFormat.pdf => throw ArgumentError.value(
    format,
    'format',
    'a binary format: parse the file bytes instead',
  ),
};
