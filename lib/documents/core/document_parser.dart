import 'package:mozhi/documents/core/document_format.dart';
import 'package:mozhi/documents/core/parsed_document.dart';
import 'package:mozhi/documents/core/parsers/json_parser.dart';
import 'package:mozhi/documents/core/parsers/markdown_parser.dart';
import 'package:mozhi/documents/core/parsers/plain_text_parser.dart';
import 'package:mozhi/documents/core/parsers/subtitle_parser.dart';



/// Parses [text] as [format].
///
/// Throws [DocumentParseException] when [text] is not valid in [format]
/// (only JSON is strict; the other formats accept any text).
ParsedDocument parseDocument(String text, DocumentFormat format) =>
    switch (format) {
      DocumentFormat.plainText => parsePlainText(text),
      DocumentFormat.markdown => parseMarkdown(text),
      DocumentFormat.srt || DocumentFormat.vtt => parseSubtitles(text, format),
      DocumentFormat.json => parseJson(text),
    };
