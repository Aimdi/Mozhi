import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/widgets/image_translate_progress.dart';
import 'package:mozhi/image_translate/widgets/translated_image_overlay.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// The picked image (or the translated rendering, with an
/// Original/Translated toggle) in a zoomable viewer, covered by the
/// progress indicator while translating.
///
/// When on-device recognition found where the text is, an Overlay | Text
/// toggle chooses between the photo with the translation drawn over it
/// ([TranslatedImageOverlay], the default, with a "hold to see the
/// original" button) and the plain photo with the text below.
///
/// With [expand] the viewer fills the available height (wide layouts),
/// otherwise it is [height] tall.
///
/// The photo is decoded at most [maxDecodedSide] pixels on its long side
/// (a photo shared from another app can be a 40 MB original; the picker
/// downscales its own to the same size): the text is read from the file,
/// not from what is shown.
class ImageTranslatePreview extends StatelessWidget {
  const new({this.expand = false, this.height = 360, super.key});

  /// The longest side the shown photo is decoded at.
  static const maxDecodedSide = 2048;

  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<ImageTranslateCubit>().state;
    final image = state.image;
    if (image == null) return const SizedBox.shrink();
    final result = state.result;
    final translated = result?.translatedImage;
    final showTranslated = translated != null && !state.showOriginal;
    final bytes = showTranslated ? translated : image.bytes;
    final overlay = state.showsOverlay ? result : null;
    final cubit = context.read<ImageTranslateCubit>();

    // X media: a rounded frame with a hairline edge.
    final viewer = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppLook.of(context).cardRadius,
        border: Border.all(color: AppPalette.of(context).hairline),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            key: const Key('image_translate_viewer'),
            maxScale: 6,
            child: Center(
              child: overlay != null
                  ? TranslatedImageOverlay(
                      key: const Key('image_translate_overlay'),
                      image: image.bytes,
                      layout: overlay.layout!,
                      translations: overlay.translatedParagraphs,
                      source: _sourceOf(state),
                      target: state.target,
                      showOriginal: state.showOriginal,
                    )
                  : Image(
                      image: ResizeImage(
                        MemoryImage(bytes),
                        width: maxDecodedSide,
                        height: maxDecodedSide,
                        policy: ResizeImagePolicy.fit,
                      ),
                      key: ValueKey(showTranslated),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      semanticLabel: showTranslated
                          ? l10n.imageTranslateTranslatedImageLabel
                          : l10n.imageTranslateOriginalImageLabel,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          if (overlay != null && !state.isWorking)
            PositionedDirectional(
              end: 12,
              bottom: 12,
              child: HoldToShowOriginalButton(
                key: const Key('image_translate_hold_original'),
                showing: state.showOriginal,
                onChanged: (showing) =>
                    cubit.setShowOriginal(showOriginal: showing),
              ),
            ),
          if (state.isWorking)
            ColoredBox(
              color: theme.colorScheme.scrim.withValues(alpha: 0.32),
              child: const Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(16),
                  child: ImageTranslateProgress(),
                ),
              ),
            ),
        ],
      ),
    );

    return Column(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (translated != null) ...[
          Center(
            child: SegmentedButton<bool>(
              key: const Key('image_translate_toggle'),
              segments: [
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(l10n.imageTranslateShowOriginal),
                ),
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.translate),
                  label: Text(l10n.imageTranslateShowTranslated),
                ),
              ],
              selected: {showTranslated},
              onSelectionChanged: (selection) =>
                  cubit.setShowOriginal(showOriginal: !selection.first),
            ),
          ),
          const SizedBox(height: 12),
        ] else if (result?.hasOverlay ?? false) ...[
          Center(
            child: SegmentedButton<ImageResultMode>(
              key: const Key('image_translate_mode_toggle'),
              segments: [
                ButtonSegment(
                  value: ImageResultMode.overlay,
                  icon: const Icon(Icons.layers_outlined),
                  label: Text(l10n.imageTranslateModeOverlay),
                ),
                ButtonSegment(
                  value: ImageResultMode.text,
                  icon: const Icon(Icons.notes),
                  label: Text(l10n.imageTranslateModeText),
                ),
              ],
              selected: {state.resultMode},
              onSelectionChanged: (selection) =>
                  cubit.setResultMode(selection.first),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (expand)
          Expanded(child: viewer)
        else
          SizedBox(height: height, child: viewer),
      ],
    );
  }
}

/// The language of the text in the photo: the chosen source, else the one
/// the translator detected.
Language _sourceOf(ImageTranslateState state) {
  if (!state.source.isAuto) return state.source;
  final detected = state.result?.detectedSource;
  if (detected == null || detected.isEmpty) return state.source;
  return LanguageCatalog.byCode(detected) ??
      Language(code: detected, name: detected);
}
