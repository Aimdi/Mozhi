import 'dart:typed_data';

import 'package:mozhi/documents/pdf/pdf_scratch.dart';

/// No files in a browser: PDFs are read in the Android app.
PdfScratch defaultPdfScratch() => const _NoScratch();

class _NoScratch implements PdfScratch {
  const new();

  @override
  Future<String> write(Uint8List bytes) =>
      Future.error(UnsupportedError('No PDF files on the web'));

  @override
  Future<String> newPath() =>
      Future.error(UnsupportedError('No PDF files on the web'));

  @override
  Future<Uint8List> take(String path) =>
      Future.error(UnsupportedError('No PDF files on the web'));

  @override
  Future<void> delete(String path) async {}
}
