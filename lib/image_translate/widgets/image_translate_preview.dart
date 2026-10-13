import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/widgets/image_translate_progress.dart';
import 'package:mozhi/l10n/l10n.dart';

/// The picked image (or the translated rendering, with an
/// Original/Translated toggle) in a zoomable viewer, covered by the
/// progress indicator while translating.
///
/// With [expand] the viewer fills the available height (wide layouts),
/// otherwise it is [height] tall.
class ImageTranslatePreview extends StatelessWidget {
  const ImageTranslatePreview({
    this.expand = false,
    this.height = 360,
    super.key,
  });

  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<ImageTranslateCubit>().state;
    final image = state.image;
    if (image == null) return const SizedBox.shrink();
    final translated = state.result?.translatedImage;
    final showTranslated = translated != null && !state.showOriginal;
    final bytes = showTranslated ? translated : image.bytes;

    final viewer = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            key: const Key('image_translate_viewer'),
            maxScale: 6,
            child: Center(
              child: Image.memory(
                bytes,
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
              onSelectionChanged: (selection) => context
                  .read<ImageTranslateCubit>()
                  .setShowOriginal(showOriginal: !selection.first),
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
