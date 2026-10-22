import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/image_translate/data/image_encoder.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/overlay_painting.dart';
import 'package:mozhi/image_translate/widgets/translated_image_overlay.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:translation_repository/translation_repository.dart';

/// Renders the photo with its translation drawn over it as a PNG
/// (injectable for tests).
abstract interface class OverlayImageRenderer {
  /// [image] (encoded) at its own resolution (the long side capped at
  /// [maxSide]) with the overlay of [translations] over [layout] (see
  /// [layoutOverlay]). Throws [ImageTranslateException] (`invalidImage`)
  /// when [image] cannot be decoded.
  Future<Uint8List> render(
    Uint8List image,
    TextLayout layout,
    List<String> translations, {
    required TextDirection direction,
    Locale? locale,
    TextStyle style,
    int maxSide,
  });
}

/// Longest side of a saved or shared overlay image: a 12 MP photo
/// (4000 x 3000) keeps its resolution; larger ones are scaled down so that
/// rendering stays within memory.
const overlayExportMaxSide = 4096;

/// [OverlayImageRenderer] drawing with `dart:ui` on the device: nothing is
/// uploaded.
class UiOverlayImageRenderer implements OverlayImageRenderer {
  const new();

  @override
  Future<Uint8List> render(
    Uint8List image,
    TextLayout layout,
    List<String> translations, {
    required TextDirection direction,
    Locale? locale,
    TextStyle style = const TextStyle(),
    int maxSide = overlayExportMaxSide,
  }) async {
    final ui.Image photo;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(image);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) =>
            UiImageEncoder.targetSize(width, height, maxSide),
      );
      photo = (await codec.getNextFrame()).image;
      codec.dispose();
    } on Object catch (error) {
      throw ImageTranslateException(
        ImageTranslateErrorKind.invalidImage,
        cause: error,
      );
    }
    final labels = layoutOverlay(
      layout,
      translations,
      direction: direction,
      locale: locale,
      style: style,
    );
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawImage(
          photo,
          Offset.zero,
          Paint()..filterQuality = FilterQuality.high,
        )
        ..scale(
          photo.width / math.max(1, layout.width),
          photo.height / math.max(1, layout.height),
        );
      for (final label in labels) {
        label.paint(canvas);
      }
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(photo.width, photo.height);
      picture.dispose();
      try {
        final data = (await rendered.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        rendered.dispose();
      }
    } finally {
      photo.dispose();
      for (final label in labels) {
        label.dispose();
      }
    }
  }
}

/// The platform services saving and sharing the overlay image uses (the
/// document translator's: a save dialog or a download, the share sheet);
/// replaceable in tests.
abstract final class OverlayExport {
  @visibleForTesting
  static DocumentFileService files = const PlatformDocumentFileService();

  @visibleForTesting
  static OverlayImageRenderer renderer = const UiOverlayImageRenderer();

  /// Name of the saved or shared file.
  static const fileName = 'translated-photo.png';
}

/// What to do with the rendered overlay image.
enum OverlayExportAction { save, share }

/// Renders the photo of [result] with its overlay ([OverlayExport.renderer])
/// and saves it (a save dialog, a download on the web) or shares it (the
/// system share sheet, anchored at [origin]), then confirms or says what
/// failed in a snackbar. Nothing is uploaded: only the user's own choice in
/// the share sheet sends the file anywhere.
Future<void> exportOverlayImage(
  BuildContext context, {
  required OverlayExportAction action,
  required PickedImage image,
  required ImageTranslation result,
  required Language target,
  Rect? origin,
}) async {
  final layout = result.layout;
  if (layout == null) return;
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final style = overlayTextStyle(context);
  void say(String message) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  final files = OverlayExport.files;
  if (action == OverlayExportAction.share && !files.canShareFiles) {
    say(l10n.imageTranslateShareUnsupported);
    return;
  }
  final Uint8List png;
  try {
    png = await OverlayExport.renderer.render(
      image.bytes,
      layout,
      result.translatedParagraphs,
      direction: textDirectionForLanguage(target) ?? TextDirection.ltr,
      locale: localeForLanguage(target),
      style: style,
    );
  } on Object {
    say(l10n.imageTranslateImageExportFailed);
    return;
  }
  try {
    switch (action) {
      case OverlayExportAction.save:
        final saved = await files.saveFile(
          fileName: OverlayExport.fileName,
          bytes: png,
          mimeType: 'image/png',
        );
        if (saved) say(l10n.imageTranslateImageSaved);
      case OverlayExportAction.share:
        await files.shareFile(
          fileName: OverlayExport.fileName,
          bytes: png,
          mimeType: 'image/png',
          origin: origin,
        );
    }
  } on ShareUnsupportedException {
    say(l10n.imageTranslateShareUnsupported);
  } on Object {
    say(l10n.imageTranslateImageExportFailed);
  }
}
