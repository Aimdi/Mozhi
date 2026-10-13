/// Pure-Dart document translation core: format detection, parsers that
/// split documents into translatable segments, chunking and the
/// [DocumentTranslator] that drives the translation repository.
library;

export 'batch_codec.dart';
export 'chunker.dart';
export 'document_builder.dart';
export 'document_format.dart';
export 'document_parser.dart';
export 'document_translator.dart';
export 'parsed_document.dart';
export 'parsers/json_parser.dart' show IcuMessageParser, looksLikeNaturalLanguage;
export 'parsers/markdown_parser.dart';
export 'parsers/plain_text_parser.dart';
export 'parsers/protected_patterns.dart';
export 'parsers/subtitle_parser.dart';
export 'source_line.dart';
export 'text_encoding.dart';
