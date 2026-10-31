import 'package:flutter/services.dart';
import 'package:mozhi/documents/pdf/pdf_pages.dart';

/// [PdfPages] on Android: `PdfPagesPlugin.kt` on the channel [channelName]
/// (framework `PdfRenderer` and `PdfDocument`, off the main thread, one
/// document at a time).
///
/// Everything the platform answers is checked before it is used: page
/// counts and sizes, that a rendered page has as many bytes as its size
/// says, within [PdfLimits], and that every line of a text layer has text
/// and a finite box (at most [PdfLimits.maxTextLines] lines of
/// [PdfLimits.maxTextLineLength] characters).
class MethodChannelPdfPages implements PdfPages {
  new({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'mozhi/pdf_pages';

  final MethodChannel _channel;

  @override
  bool get isSupported => true;

  @override
  Future<PdfInfo> open(String path) async {
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<Object?, Object?>('open', {
        'path': path,
      });
    } on PlatformException catch (error) {
      throw PdfOpenException(kind: _openErrorKind(error.code));
    } on MissingPluginException {
      throw const PdfOpenException(kind: PdfOpenErrorKind.unsupported);
    }
    final widths = answer?['widths'];
    final heights = answer?['heights'];
    if (widths is! List ||
        heights is! List ||
        widths.length != heights.length) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    if (widths.isEmpty) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
    }
    if (widths.length > PdfLimits.maxPages) {
      throw const PdfOpenException(kind: PdfOpenErrorKind.tooLarge);
    }
    final sizes = <Size>[];
    for (var i = 0; i < widths.length; i++) {
      final width = widths[i];
      final height = heights[i];
      if (width is! num || height is! num || width <= 0 || height <= 0) {
        throw const PdfOpenException(kind: PdfOpenErrorKind.damaged);
      }
      sizes.add(Size(width.toDouble(), height.toDouble()));
    }
    return PdfInfo(pageSizes: List.unmodifiable(sizes));
  }

  static PdfOpenErrorKind _openErrorKind(String code) => switch (code) {
    'encrypted' => PdfOpenErrorKind.encrypted,
    'too_large' => PdfOpenErrorKind.tooLarge,
    'unsupported' => PdfOpenErrorKind.unsupported,
    _ => PdfOpenErrorKind.damaged,
  };

  @override
  Future<PdfPageImage> render(int page, {required int maxPixels}) async {
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<Object?, Object?>('render', {
        'page': page,
        'maxPixels': maxPixels.clamp(1, PdfLimits.maxPixels),
      });
    } on PlatformException catch (error) {
      throw PdfRenderException(page: page, cause: error.code);
    } on MissingPluginException catch (error) {
      throw PdfRenderException(page: page, cause: error);
    }
    final pixels = answer?['pixels'];
    final width = answer?['width'];
    final height = answer?['height'];
    final bytesPerPixel = answer?['bytesPerPixel'] ?? 4;
    if (pixels is! Uint8List ||
        width is! int ||
        height is! int ||
        (bytesPerPixel != 1 && bytesPerPixel != 4) ||
        width <= 0 ||
        height <= 0 ||
        width * height > PdfLimits.maxPixels ||
        pixels.length != width * height * (bytesPerPixel as int)) {
      throw PdfRenderException(page: page, cause: 'invalid answer');
    }
    return PdfPageImage(
      pixels: pixels,
      width: width,
      height: height,
      bytesPerPixel: bytesPerPixel,
    );
  }

  /// `text({page})` answers `{lines: [{text, left, top, right, bottom}]}`
  /// (points), or null before Android 15. A failure reads as a page
  /// without text (text recognition reads it then).
  @override
  Future<List<PdfTextLine>?> readText(int page) async {
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<Object?, Object?>('text', {
        'page': page,
      });
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return null;
    }
    if (answer == null) return null;
    final lines = answer['lines'];
    if (lines is! List) return const [];
    return List.unmodifiable([
      for (final line in lines.take(PdfLimits.maxTextLines)) ?_lineOf(line),
    ]);
  }

  static PdfTextLine? _lineOf(Object? line) {
    if (line is! Map) return null;
    final text = line['text'];
    final left = line['left'];
    final top = line['top'];
    final right = line['right'];
    final bottom = line['bottom'];
    if (text is! String ||
        text.trim().isEmpty ||
        left is! num ||
        top is! num ||
        right is! num ||
        bottom is! num) {
      return null;
    }
    final rect = Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    );
    if (!rect.isFinite) return null;
    var cut = text;
    if (cut.length > PdfLimits.maxTextLineLength) {
      var end = PdfLimits.maxTextLineLength;
      // Never inside a surrogate pair.
      final last = cut.codeUnitAt(end - 1);
      if (last >= 0xD800 && last <= 0xDBFF) end--;
      cut = cut.substring(0, end);
    }
    // Some files have their boxes upside down.
    return PdfTextLine(
      text: cut,
      rect: Rect.fromLTRB(
        rect.left < rect.right ? rect.left : rect.right,
        rect.top < rect.bottom ? rect.top : rect.bottom,
        rect.left < rect.right ? rect.right : rect.left,
        rect.top < rect.bottom ? rect.bottom : rect.top,
      ),
    );
  }

  @override
  Future<void> write(String outputPath, List<PdfOutputPage> pages) async {
    try {
      await _channel.invokeMethod<void>('write', {
        'path': outputPath,
        'pages': [for (final page in pages) _pageArguments(page)],
      });
    } on PlatformException catch (error) {
      throw PdfWriteException(cause: error.code);
    } on MissingPluginException catch (error) {
      throw PdfWriteException(cause: error);
    }
  }

  static Map<String, Object> _pageArguments(PdfOutputPage page) => {
    'page': page.sourcePage,
    'width': page.size.width,
    'height': page.size.height,
    'blocks': [
      for (final block in page.blocks)
        {
          'left': block.rect.left,
          'top': block.rect.top,
          'right': block.rect.right,
          'bottom': block.rect.bottom,
          'text': block.text,
          'color': block.color.toARGB32(),
          'background': block.background.toARGB32(),
          'rtl': block.direction == TextDirection.rtl,
          'align': block.align.name,
          'fontSize': block.fontSize,
        },
    ],
  };

  @override
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // Nothing was open, or it is closed already.
    } on MissingPluginException {
      // No plugin: nothing was opened either.
    }
  }
}
