import 'package:mozhi/documents/pdf/pdf_pages.dart';

/// [PdfPages] where PDFs are not read (the web app, platforms without the
/// Android plugin): [open] fails with [PdfOpenErrorKind.unsupported].
class UnsupportedPdfPages implements PdfPages {
  const new();

  @override
  bool get isSupported => false;

  @override
  Future<PdfInfo> open(String path) =>
      Future.error(const PdfOpenException(kind: PdfOpenErrorKind.unsupported));

  @override
  Future<PdfPageImage> render(int page, {required int maxPixels}) =>
      Future.error(PdfRenderException(page: page, cause: 'unsupported'));

  @override
  Future<List<PdfTextLine>?> readText(int page) async => null;

  @override
  Future<void> write(String outputPath, List<PdfOutputPage> pages) =>
      Future.error(const PdfWriteException(cause: 'unsupported'));

  @override
  Future<void> close() async {}
}
