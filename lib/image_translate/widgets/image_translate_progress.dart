import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Spinner, what is happening (plus a "still working" note for slow
/// requests) and a cancel button.
class ImageTranslateProgress extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<ImageTranslateCubit>().state;
    final palette = AppPalette.of(context);
    return Card(
      key: const Key('image_translate_progress'),
      elevation: 2,
      color: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.cardBorderRadius,
        side: BorderSide(color: palette.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: theme.colorScheme.primary,
                backgroundColor: palette.hairline,
              ),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  imagePhaseMessage(l10n, state),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (state.slow) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.imageTranslateSlow,
                  key: const Key('image_translate_slow'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('image_translate_cancel_button'),
                onPressed: context.read<ImageTranslateCubit>().cancel,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: const StadiumBorder(),
                  side: BorderSide(color: palette.hairline),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
                icon: const Icon(Icons.close),
                label: Text(l10n.commonCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
