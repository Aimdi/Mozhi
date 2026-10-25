import 'package:flutter/foundation.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/core/office/office.dart';

/// Parses a text document (`parseDocument`, replaceable in tests).
typedef TextDocumentParser = ParsedDocument Function(
  String text,
  DocumentFormat format, {
  String? targetLanguage,
});

/// Parses [text] with [parser] in a background isolate (on the web, where
/// there are none, after a pause on the same thread). Errors arrive as they
/// were thrown.
Future<ParsedDocument> parseTextInBackground(
  TextDocumentParser parser,
  String text,
  DocumentFormat format, {
  String? targetLanguage,
}) => compute(_parseText, (parser, text, format, targetLanguage));

/// Parses an office document or e-book in a background isolate (see
/// [parseTextInBackground]). Errors ([PackageParseException]) arrive as
/// they were thrown.
Future<PackagedDocument> parsePackageInBackground(
  Uint8List bytes,
  DocumentFormat format, {
  String? targetLanguage,
}) => compute(_parsePackage, (bytes, format, targetLanguage));

/// Renders [document] with [translations] in a background isolate.
Future<Uint8List> renderPackageInBackground(
  PackagedDocument document,
  List<String?> translations,
) => compute(_render, (document, translations));

ParsedDocument _parseText(
  (TextDocumentParser parser, String text, DocumentFormat format, String?) job,
) => job.$1(job.$2, job.$3, targetLanguage: job.$4);

PackagedDocument _parsePackage(
  (Uint8List bytes, DocumentFormat format, String? target) job,
) => parsePackagedDocument(job.$1, job.$2, targetLanguage: job.$3);

Uint8List _render(
  (PackagedDocument document, List<String?> translations) job,
) => job.$1.render(job.$2);
