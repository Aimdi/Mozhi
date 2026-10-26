import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/image_translate/widgets/image_translate_links.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/live_camera_entry.dart';

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

    // The tabs' empty state (an accent icon, a bold headline, a quiet
    // hint and the pick buttons), then the available methods.
    return Column(
      key: const Key('image_translate_empty_state'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: TabHero(
            icon: Icons.photo_camera_outlined,
            title: l10n.imageTranslateHeroTitle,
            body: l10n.imageTranslateEmptyBody,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('image_translate_gallery_button'),
                  onPressed: canPick
                      ? () =>
                            unawaited(cubit.pickImage(ImagePickSource.gallery))
                      : null,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(l10n.imageTranslatePickGallery),
                ),
                if (canUseCamera)
                  OutlinedButton.icon(
                    key: const Key('image_translate_camera_button'),
                    onPressed: canPick
                        ? () =>
                              unawaited(cubit.pickImage(ImagePickSource.camera))
                        : null,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text(l10n.imageTranslateTakePhoto),
                  ),
                // Live camera (W7-A): the Android app only.
                if (liveCameraOffered)
                  Tooltip(
                    message: l10n.liveCameraOpenHint,
                    child: OutlinedButton.icon(
                      key: const Key('image_translate_live_camera_button'),
                      onPressed: () => unawaited(openLiveCamera(context)),
                      icon: const Icon(Icons.center_focus_weak),
                      label: Text(l10n.liveCameraOpen),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
                style: theme.textTheme.titleLarge,
              ),
            ),
          ),
          // Recommended first (the order of ImageTranslateMethodKind).
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
                  l10n.imageTranslateMethodMozhiGoogle,
                ImageTranslateMethodKind.onDevice =>
                  l10n.imageTranslateMethodOnDevice,
              }),
              subtitle: Text(imageMethodDescription(l10n, kind)),
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
        borderRadius: AppRadius.cardBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.imageTranslateNoMethodsTitle,
                style: theme.textTheme.titleMedium,
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
                  onPressed: () => unawaited(
                    context.push<Object?>(ImageTranslateLinks.providers),
                  ),
                  child: Text(l10n.translateProvidersAction),
                ),
                TextButton(
                  key: const Key('image_translate_instances_button'),
                  onPressed: () => unawaited(
                    context.push<Object?>(ImageTranslateLinks.instances),
                  ),
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
