import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_translate_links.dart';
import 'package:mozhi/image_translate/widgets/overlay_painting.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:translation_repository/translation_repository.dart';

/// The photo with each paragraph's translation drawn over it, in place of
/// the original text (see [layoutOverlay]), like a camera translator, all
/// on the device.
///
/// It scales to the space it gets (put it in an `InteractiveViewer` to
/// zoom and pan). Each paragraph is a button for screen readers, read as
/// its translation with the original as hint; tapping one opens a sheet
/// with both and copy buttons. While [showOriginal] the photo is shown
/// without the overlay (it fades unless animations are reduced).
class TranslatedImageOverlay extends StatefulWidget {
  const new({
    required this.image,
    required this.layout,
    required this.translations,
    required this.target,
    this.source = Language.auto,
    this.showOriginal = false,
    super.key,
  });

  /// The encoded photo (the one that was read).
  final Uint8List image;
  final TextLayout layout;

  /// One per paragraph of [layout] (empty ones are not drawn).
  final List<String> translations;
  final Language target;

  /// The language of the text in the photo (for screen readers).
  final Language source;
  final bool showOriginal;

  /// How long the overlay takes to fade in and out.
  static const fadeDuration = Duration(milliseconds: 180);

  @override
  State<TranslatedImageOverlay> createState() => _TranslatedImageOverlayState();
}

class _TranslatedImageOverlayState extends State<TranslatedImageOverlay> {
  List<OverlayLabel> _labels = const [];
  Object? _key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(TranslatedImageOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  /// Lays the labels out again only when what they show changed.
  void _update() {
    final style = overlayTextStyle(context);
    final key = (
      widget.layout,
      Object.hashAll(widget.translations),
      widget.target,
      style,
    );
    if (key == _key) return;
    _key = key;
    _dispose();
    _labels = layoutOverlay(
      widget.layout,
      widget.translations,
      direction: textDirectionForLanguage(widget.target) ?? TextDirection.ltr,
      locale: localeForLanguage(widget.target),
      style: style,
    );
  }

  void _dispose() {
    for (final label in _labels) {
      label.dispose();
    }
    _labels = const [];
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final layout = widget.layout;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return FittedBox(
      child: SizedBox(
        width: layout.width.toDouble(),
        height: layout.height.toDouble(),
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.memory(
                widget.image,
                fit: BoxFit.fill,
                // The size the text was read at is plenty (at most 2500 px
                // on the long side), and saves memory for large photos.
                cacheWidth: layout.width,
                gaplessPlayback: true,
                semanticLabel: widget.showOriginal
                    ? l10n.imageTranslateOriginalImageLabel
                    : l10n.imageTranslateOverlayImageLabel,
              ),
            ),
            Positioned.fill(
              child: AnimatedOpacity(
                key: const Key('image_translate_overlay_layer'),
                opacity: widget.showOriginal ? 0 : 1,
                duration: reduceMotion
                    ? Duration.zero
                    : TranslatedImageOverlay.fadeDuration,
                child: Stack(
                  children: [
                    for (final label in _labels)
                      Positioned.fromRect(
                        rect: label.fill,
                        child: _Paragraph(
                          label: label,
                          source: widget.source,
                          target: widget.target,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The font of the overlay: the app's body font, medium weight.
TextStyle overlayTextStyle(BuildContext context) => TextStyle(
  fontFamily: Theme.of(context).textTheme.bodyLarge?.fontFamily,
  fontFamilyFallback: Theme.of(context).textTheme.bodyLarge?.fontFamilyFallback,
  fontWeight: FontWeight.w500,
);

class _Paragraph extends StatelessWidget {
  const new({required this.label, required this.source, required this.target});

  final OverlayLabel label;
  final Language source;
  final Language target;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    void open() => unawaited(
      showOverlayParagraph(
        context,
        original: label.original,
        translation: label.translation,
        source: source,
        target: target,
      ),
    );
    return Semantics(
      key: Key('image_translate_overlay_paragraph_${label.index}'),
      container: true,
      button: true,
      sortKey: OrdinalSortKey(label.index.toDouble()),
      attributedLabel: _attributed(label.translation, target),
      attributedHint: _attributed(label.original, source),
      textDirection: textDirectionForLanguage(target),
      onTapHint: l10n.imageTranslateOverlayParagraphAction,
      onTap: open,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: open,
        child: CustomPaint(
          size: label.fill.size,
          painter: _LabelPainter(label),
        ),
      ),
    );
  }

  static AttributedString _attributed(String text, Language language) {
    final locale = localeForLanguage(language);
    return AttributedString(
      text,
      attributes: [
        if (locale != null && text.isNotEmpty)
          LocaleStringAttribute(
            range: TextRange(start: 0, end: text.length),
            locale: locale,
          ),
      ],
    );
  }
}

class _LabelPainter extends CustomPainter {
  new(this.label);

  final OverlayLabel label;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(-label.fill.left, -label.fill.top);
    label.paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LabelPainter oldDelegate) =>
      !identical(oldDelegate.label, label);
}

/// A sheet with one paragraph's [original] text and its [translation],
/// each selectable and with a copy button.
Future<void> showOverlayParagraph(
  BuildContext context, {
  required String original,
  required String translation,
  required Language source,
  required Language target,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => _ParagraphSheet(
    original: original,
    translation: translation,
    source: source,
    target: target,
  ),
);

class _ParagraphSheet extends StatelessWidget {
  const new({
    required this.original,
    required this.translation,
    required this.source,
    required this.target,
  });

  final String original;
  final String translation;
  final Language source;
  final Language target;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    Widget section({
      required Key key,
      required String label,
      required String text,
      required Language language,
      required String copyTooltip,
      required TextStyle? style,
    }) => Padding(
      key: key,
      padding: const EdgeInsetsDirectional.fromSTEB(24, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(label, style: theme.textTheme.titleSmall),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  text,
                  style: style?.copyWith(locale: localeForLanguage(language)),
                  textDirection:
                      textDirectionForLanguage(language) ??
                      textDirectionForText(text),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: copyTooltip,
            onPressed: () => unawaited(copyImageTranslation(context, text)),
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            section(
              key: const Key('image_translate_overlay_sheet_original'),
              label: l10n.imageTranslateSourceTextLabel,
              text: original,
              language: source,
              copyTooltip: l10n.imageTranslateCopyOriginal,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: palette.secondaryText,
              ),
            ),
            section(
              key: const Key('image_translate_overlay_sheet_translation'),
              label: l10n.imageTranslateTranslationLabel,
              text: translation,
              language: target,
              copyTooltip: l10n.imageTranslateCopyTranslation,
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Original": shows the photo without the overlay while held (and, for
/// screen readers and switch access, toggles it on a tap).
class HoldToShowOriginalButton extends StatelessWidget {
  const new({required this.showing, required this.onChanged, super.key});

  /// Whether the original is shown now.
  final bool showing;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Tooltip(
      message: l10n.imageTranslateHoldOriginal,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        toggled: showing,
        label: l10n.imageTranslateHoldOriginal,
        onTap: () => onChanged(!showing),
        excludeSemantics: true,
        child: Listener(
          onPointerDown: (_) => onChanged(true),
          onPointerUp: (_) => onChanged(false),
          onPointerCancel: (_) => onChanged(false),
          child: Material(
            color: showing ? colors.primary : colors.surfaceContainerHigh,
            shape: const StadiumBorder(),
            elevation: 2,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.flip_outlined,
                      size: 20,
                      color: showing ? colors.onPrimary : colors.onSurface,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.imageTranslateShowOriginal,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: showing ? colors.onPrimary : colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
