import 'dart:typed_data';

import 'package:mozhi/documents/pdf/pdf_scratch_web.dart'
    if (dart.library.io) 'package:mozhi/documents/pdf/pdf_scratch_io.dart'
    as platform;

/// Short-lived files of PDF translation in the app's private cache: the
/// copy of the picked PDF that the platform opens (and deletes once it is
/// open) and the translated PDF until its bytes are read back.
abstract interface class PdfScratch {
  /// Writes [bytes] to a new file and returns its path.
  Future<String> write(Uint8List bytes);

  /// A path for a new file (not created).
  Future<String> newPath();

  /// Reads the file at [path] and deletes it.
  Future<Uint8List> take(String path);

  /// Deletes the file at [path] if it is still there.
  Future<void> delete(String path);
}

/// The platform's [PdfScratch]: `<cache>/pdf_pages/` on Android; none on
/// the web (its methods throw [UnsupportedError]).
PdfScratch defaultPdfScratch() => platform.defaultPdfScratch();
