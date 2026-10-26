import 'dart:ui' show Color, Rect, Size, TextDirection;

import 'package:flutter/foundation.dart';

/// Limits of PDF translation, the same on the Kotlin side
/// (`PdfPagesPlugin.kt`), which enforces them again.
abstract final class PdfLimits {
  /// Largest PDF file accepted.
  static const int maxBytes = 25 * 1024 * 1024;

  /// Most pages a PDF may have.
  static const int maxPages = 200;

  /// Most pixels of a page rendered for reading (8 megapixels).
  static const int maxPixels = 8000000;

  /// The resolution pages are rendered at for reading, at most (a page
  /// larger than Letter gets less to stay within [maxPixels]).
  static const int readDpi = 300;
}

/// The pages of one PDF on the device: Android's framework `PdfRenderer`
/// opens and renders them and `PdfDocument` writes the translated file
/// (`PdfPagesPlugin.kt`, channel `mozhi/pdf_pages`). One document is open at
/// a time; opening another closes the first.
abstract interface class PdfPages {
  /// Whether PDFs can be read here (Android).
  bool get isSupported;

  /// Opens the PDF at [path] (a file in the app's private cache, which is
  /// deleted once it is open): its page count and page sizes in points.
  /// Throws [PdfOpenException].
  Future<PdfInfo> open(String path);

  /// Renders page [page] (0-based) of the open PDF on white, with at most
  /// [maxPixels] pixels. Throws [PdfRenderException].
  Future<PdfPageImage> render(int page, {required int maxPixels});

  /// Writes the translated PDF to [outputPath] (a file in the app's private
  /// cache): every page of [pages] is its source page as the background,
  /// each block's area covered in its background colour and its text drawn
  /// as real text (selectable, searchable, read aloud), shrunk to fit.
  /// Throws [PdfWriteException].
  Future<void> write(String outputPath, List<PdfOutputPage> pages);

  /// Closes the open PDF (nothing happens when none is open).
  Future<void> close();
}

/// What [PdfPages.open] found.
@immutable
class PdfInfo {
  const new({required this.pageSizes});

  /// The size of every page in points (1/72 inch), as the reader shows it.
  final List<Size> pageSizes;

  int get pageCount => pageSizes.length;

  @override
  bool operator ==(Object other) =>
      other is PdfInfo && listEquals(other.pageSizes, pageSizes);

  @override
  int get hashCode => Object.hashAll(pageSizes);

  @override
  String toString() => 'PdfInfo($pageCount pages)';
}

/// A rendered page: [width] x [height] pixels, [bytesPerPixel] 4 (RGBA,
/// opaque) or 1 (grey), rows without padding.
@immutable
class PdfPageImage {
  const new({
    required this.pixels,
    required this.width,
    required this.height,
    this.bytesPerPixel = 4,
  });

  final Uint8List pixels;
  final int width;
  final int height;
  final int bytesPerPixel;

  int get bytesPerLine => width * bytesPerPixel;

  @override
  String toString() => 'PdfPageImage(${width}x$height, $bytesPerPixel bpp)';
}

/// Where a translated text sits in its box (logical: start is the left
/// for left-to-right text, the right for right-to-left text).
enum PdfTextAlign { start, center, end }

/// One translated block of a [PdfOutputPage].
@immutable
class PdfTextBlock {
  const new({
    required this.rect,
    required this.text,
    required this.color,
    required this.background,
    required this.direction,
    this.align = PdfTextAlign.start,
    this.fontSize = 12,
  });

  /// Where the original text was, in points from the page's top left.
  final Rect rect;

  /// The translation, drawn as real text.
  final String text;

  /// The text's colour (opaque).
  final Color color;

  /// The colour [rect] is covered in before the text is drawn (opaque).
  final Color background;

  /// The direction of [text] (from the target language).
  final TextDirection direction;
  final PdfTextAlign align;

  /// The largest font size in points (the original's line pitch); the text
  /// is drawn smaller when it needs to, to fit [rect].
  final double fontSize;

  @override
  bool operator ==(Object other) =>
      other is PdfTextBlock &&
      other.rect == rect &&
      other.text == text &&
      other.color == color &&
      other.background == background &&
      other.direction == direction &&
      other.align == align &&
      other.fontSize == fontSize;

  @override
  int get hashCode =>
      Object.hash(rect, text, color, background, direction, align, fontSize);

  @override
  String toString() => 'PdfTextBlock($text, $rect)';
}

/// One page of the translated PDF: [sourcePage] (0-based) of the open PDF
/// as the background, [size] in points, and the translated [blocks] (none:
/// the page is kept as it is).
@immutable
class PdfOutputPage {
  const new({
    required this.sourcePage,
    required this.size,
    this.blocks = const [],
  });

  final int sourcePage;
  final Size size;
  final List<PdfTextBlock> blocks;

  @override
  bool operator ==(Object other) =>
      other is PdfOutputPage &&
      other.sourcePage == sourcePage &&
      other.size == size &&
      listEquals(other.blocks, blocks);

  @override
  int get hashCode => Object.hash(sourcePage, size, Object.hashAll(blocks));

  @override
  String toString() =>
      'PdfOutputPage($sourcePage, $size, ${blocks.length} blocks)';
}

/// Why a PDF could not be opened.
enum PdfOpenErrorKind {
  /// Password-protected (the framework renderer refuses it).
  encrypted,

  /// Not a PDF, or one the renderer cannot read.
  damaged,

  /// Over [PdfLimits.maxBytes] or [PdfLimits.maxPages].
  tooLarge,

  /// PDFs are not read on this platform (the web app).
  unsupported,
}

/// Thrown by [PdfPages.open].
@immutable
class PdfOpenException implements Exception {
  const new({required this.kind});

  final PdfOpenErrorKind kind;

  @override
  bool operator ==(Object other) =>
      other is PdfOpenException && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'PdfOpenException(${kind.name})';
}

/// Thrown by [PdfPages.render]: the page could not be rendered (none is
/// open, it is damaged, or it would take too much memory).
@immutable
class PdfRenderException implements Exception {
  const new({this.page, this.cause});

  final int? page;
  final Object? cause;

  @override
  String toString() => 'PdfRenderException($page, $cause)';
}

/// Thrown by [PdfPages.write]: the translated PDF could not be written.
@immutable
class PdfWriteException implements Exception {
  const new({this.cause});

  final Object? cause;

  @override
  String toString() => 'PdfWriteException($cause)';
}
