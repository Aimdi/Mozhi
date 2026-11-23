import 'dart:typed_data';

import 'package:mozhi/documents/pdf/pdf_scratch.dart';

/// The platform's [PdfScratch] on the web: an in-memory store shared with
/// `DartPdfPages`.
PdfScratch defaultPdfScratch() => WebPdfScratch.shared;

/// In-memory [PdfScratch] for the web app, keyed by virtual path.
class WebPdfScratch implements PdfScratch {
  new();

  /// Shared instance used by [defaultPdfScratch] and `DartPdfPages`.
  static final WebPdfScratch shared = WebPdfScratch();

  final Map<String, Uint8List> _files = {};
  int _next = 0;

  @override
  Future<String> write(Uint8List bytes) async {
    final path = await newPath();
    _files[path] = Uint8List.fromList(bytes);
    return path;
  }

  @override
  Future<String> newPath() async => '/web/pdf_pages/${_next++}.pdf';

  @override
  Future<Uint8List> take(String path) async {
    final bytes = _files.remove(path);
    if (bytes == null) throw StateError('No PDF file at $path');
    return bytes;
  }

  @override
  Future<void> delete(String path) async {
    _files.remove(path);
  }

  /// Reads the stored bytes at [path] without removing them, or null if absent.
  Uint8List? peek(String path) => _files[path];

  /// Stores [bytes] at [path] (used by `DartPdfPages.write`).
  void put(String path, Uint8List bytes) {
    _files[path] = Uint8List.fromList(bytes);
  }

  /// Removes all stored entries (useful in tests).
  void clear() => _files.clear();
}
