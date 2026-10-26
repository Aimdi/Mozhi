import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/models/text_layout.dart';
import 'package:mozhi/image_translate/widgets/overlay_painting.dart';
import 'package:mozhi/image_translate/widgets/translated_image_overlay.dart'
    show overlayTextStyle;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/models/live_block.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:translation_repository/translation_repository.dart';

/// The translations drawn over the live preview, in place of the text the
/// camera sees: each translated block as on the photo overlay
/// ([layoutOverlay]: the block's area filled with the colour around it,
/// the translation fitted in), blocks still being read as a thin outline.
///
/// [blocks] are in pixels of the upright frame ([frameSize]), which is
/// shown at [previewRect] (in this widget's coordinates, the same aspect
/// ratio). Labels are laid out again only when a block's translation or
/// box changes. Screen readers find each translation where it is, with
/// the original as hint.
class LiveOverlay extends StatefulWidget {
  const new({
    required this.blocks,
    required this.frameSize,
    required this.previewRect,
    required this.target,
    super.key,
  });

  final List<LiveBlock> blocks;
  final Size? frameSize;
  final Rect previewRect;
  final Language target;

  @override
  State<LiveOverlay> createState() => _LiveOverlayState();
}

class _LiveOverlayState extends State<LiveOverlay> {
  final _labels = <int, _Label>{};

  @override
  void dispose() {
    for (final label in _labels.values) {
      label.label.dispose();
    }
    _labels.clear();
    super.dispose();
  }

  /// The label of each translated block, reusing the ones whose
  /// translation, box and frame did not change.
  List<_Label> _update(Size frame) {
    final style = overlayTextStyle(context);
    final direction =
        textDirectionForLanguage(widget.target) ?? TextDirection.ltr;
    final locale = localeForLanguage(widget.target);
    final kept = <int, _Label>{};
    for (final block in widget.blocks) {
      final translation = block.translation;
      if (translation == null || translation.trim().isEmpty) continue;
      final existing = _labels.remove(block.id);
      if (existing != null &&
          existing.translation == translation &&
          existing.box == block.box &&
          existing.frame == frame &&
          existing.direction == direction) {
        kept[block.id] = existing;
        continue;
      }
      existing?.label.dispose();
      final layout = TextLayout(
        width: frame.width.round(),
        height: frame.height.round(),
        paragraphs: [block.paragraph],
      );
      final laidOut = layoutOverlay(
        layout,
        [translation],
        direction: direction,
        locale: locale,
        style: style,
      );
      if (laidOut.isEmpty) continue;
      kept[block.id] = _Label(
        label: laidOut.first,
        translation: translation,
        box: block.box,
        frame: frame,
        direction: direction,
      );
    }
    for (final stale in _labels.values) {
      stale.label.dispose();
    }
    _labels
      ..clear()
      ..addAll(kept);
    return [for (final block in widget.blocks) ?kept[block.id]];
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frameSize;
    if (frame == null || frame.isEmpty || widget.previewRect.isEmpty) {
      return const SizedBox.expand();
    }
    final labels = _update(frame);
    final reading = [
      for (final block in widget.blocks)
        if (!block.hasTranslation) block.box,
    ];
    return CustomPaint(
      key: const Key('live_camera_overlay'),
      size: Size.infinite,
      painter: LiveOverlayPainter(
        labels: [for (final label in labels) label.label],
        reading: reading,
        frameSize: frame,
        previewRect: widget.previewRect,
        hintOf: context.l10n.liveCameraBlockHint,
        direction: textDirectionForLanguage(widget.target) ?? TextDirection.ltr,
      ),
    );
  }
}

class _Label {
  new({
    required this.label,
    required this.translation,
    required this.box,
    required this.frame,
    required this.direction,
  });

  final OverlayLabel label;
  final String translation;
  final Rect box;
  final Size frame;
  final TextDirection direction;
}

/// Paints [labels] (in pixels of a [frameSize] frame) and outlines of the
/// [reading] boxes scaled into [previewRect].
class LiveOverlayPainter extends CustomPainter {
  new({
    required this.labels,
    required this.reading,
    required this.frameSize,
    required this.previewRect,
    required this.hintOf,
    required this.direction,
  });

  final List<OverlayLabel> labels;
  final List<Rect> reading;
  final Size frameSize;
  final Rect previewRect;
  final String Function(String original) hintOf;
  final TextDirection direction;

  double get _scale => previewRect.width / frameSize.width;

  Rect _toScreen(Rect box) => Rect.fromLTWH(
    previewRect.left + box.left * _scale,
    previewRect.top + box.top * _scale,
    box.width * _scale,
    box.height * _scale,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xCCFFFFFF);
    final shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0x66000000);
    for (final box in reading) {
      final rect = RRect.fromRectAndRadius(
        _toScreen(box).inflate(2),
        const Radius.circular(4),
      );
      canvas
        ..drawRRect(rect, shadow)
        ..drawRRect(rect, outline);
    }
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..translate(previewRect.left, previewRect.top)
      ..scale(_scale);
    for (final label in labels) {
      label.paint(canvas);
    }
    canvas.restore();
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final visible = Offset.zero & size;
    return [
      for (final label in labels)
        // Only what shows: the preview's edges may be cut off.
        if (_toScreen(label.fill).intersect(visible) case final rect
            when rect.width > 0 && rect.height > 0)
          CustomPainterSemantics(
            rect: rect,
            properties: SemanticsProperties(
              label: label.translation,
              hint: hintOf(label.original),
              textDirection: direction,
            ),
          ),
    ];
  };

  @override
  bool shouldRepaint(LiveOverlayPainter oldDelegate) =>
      !listEquals(oldDelegate.labels, labels) ||
      !listEquals(oldDelegate.reading, reading) ||
      oldDelegate.frameSize != frameSize ||
      oldDelegate.previewRect != previewRect;

  @override
  bool shouldRebuildSemantics(LiveOverlayPainter oldDelegate) =>
      shouldRepaint(oldDelegate);
}
