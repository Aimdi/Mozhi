import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/image_translate/widgets/image_translate_links.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Shown before an image is picked: what the feature does, pick buttons and
/// the available methods (or how to get one).
class ImageTranslateEmptyState extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final (methods, canUseCamera) = context
        .select<ImageTranslateCubit, (List<ImageTranslateMethod>, bool)>(
          (cubit) => (cubit.state.methods, cubit.state.canUseCamera),
        );
    final cubit = context.read<ImageTranslateCubit>();
    final canPick = methods.isNotEmpty;
    final aiNames = [
      for (final method in methods)
        if (method.kind == ImageTranslateMethodKind.aiVision)
          method.engine!.name,
    ];
    final kinds = {for (final method in methods) method.kind};

    final palette = AppPalette.of(context);
    const pillText = TextStyle(fontWeight: FontWeight.w700);

    // X empty state: big bold headline, quiet text, pill CTAs.
    return Column(
      key: const Key('image_translate_empty_state'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: Text(
            l10n.imageTranslateEmptyTitle,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.imageTranslateEmptyBody,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: palette.secondaryText,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const Key('image_translate_gallery_button'),
              onPressed: canPick
                  ? () => unawaited(cubit.pickImage(ImagePickSource.gallery))
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                shape: const StadiumBorder(),
                textStyle: pillText,
              ),
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(l10n.imageTranslatePickGallery),
            ),
            if (canUseCamera)
              OutlinedButton.icon(
                key: const Key('image_translate_camera_button'),
                onPressed: canPick
                    ? () => unawaited(cubit.pickImage(ImagePickSource.camera))
                    : null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: const StadiumBorder(),
                  side: BorderSide(color: palette.hairline),
                  textStyle: pillText,
                ),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(l10n.imageTranslateTakePhoto),
              ),
          ],
        ),
        const SizedBox(height: 24),
        if (!canPick)
          const _NoMethods()
        else ...[
          const Hairline(),
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Semantics(
              header: true,
              child: Text(
                l10n.imageTranslateMethodsHeader,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          for (final (index, kind) in [
            for (final kind in ImageTranslateMethodKind.values)
              if (kinds.contains(kind)) kind,
          ].indexed) ...[
            if (index > 0) const Hairline(indent: 40),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                imageMethodIcon(kind),
                color: theme.colorScheme.primary,
              ),
              title: Text(switch (kind) {
                ImageTranslateMethodKind.aiVision =>
                  l10n.imageTranslateMethodAi(aiNames.join(', ')),
                ImageTranslateMethodKind.mozhiLens =>
                  l10n.imageTranslateMethodMozhi,
                ImageTranslateMethodKind.onDevice =>
                  l10n.imageTranslateMethodOnDevice,
              }, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                imageMethodDescription(l10n, kind),
                style: TextStyle(color: palette.secondaryText),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _NoMethods extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    // A flat card: hairline outline, no fill.
    return DecoratedBox(
      key: const Key('image_translate_no_methods'),
      decoration: BoxDecoration(
        border: Border.all(color: palette.hairline),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.imageTranslateNoMethodsTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.imageTranslateNoMethodsBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.secondaryText,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('image_translate_providers_button'),
                  onPressed: () => context.go(ImageTranslateLinks.providers),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  child: Text(l10n.translateProvidersAction),
                ),
                TextButton(
                  key: const Key('image_translate_instances_button'),
                  onPressed: () => context.go(ImageTranslateLinks.instances),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: Text(l10n.translateManageInstances),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
