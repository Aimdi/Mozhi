import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
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

    return Column(
      key: const Key('image_translate_empty_state'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: Icon(
            Icons.image_search_outlined,
            size: 64,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.imageTranslateEmptyTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.imageTranslateEmptyBody,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const Key('image_translate_gallery_button'),
              onPressed: canPick
                  ? () => unawaited(cubit.pickImage(ImagePickSource.gallery))
                  : null,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(l10n.imageTranslatePickGallery),
            ),
            if (canUseCamera)
              OutlinedButton.icon(
                key: const Key('image_translate_camera_button'),
                onPressed: canPick
                    ? () => unawaited(cubit.pickImage(ImagePickSource.camera))
                    : null,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(l10n.imageTranslateTakePhoto),
              ),
          ],
        ),
        const SizedBox(height: 24),
        if (!canPick)
          const _NoMethods()
        else ...[
          Text(
            l10n.imageTranslateMethodsHeader,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          for (final kind in ImageTranslateMethodKind.values)
            if (kinds.contains(kind))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(imageMethodIcon(kind)),
                title: Text(switch (kind) {
                  ImageTranslateMethodKind.aiVision =>
                    l10n.imageTranslateMethodAi(aiNames.join(', ')),
                  ImageTranslateMethodKind.mozhiLens =>
                    l10n.imageTranslateMethodMozhi,
                  ImageTranslateMethodKind.onDevice =>
                    l10n.imageTranslateMethodOnDevice,
                }),
                subtitle: Text(imageMethodDescription(l10n, kind)),
              ),
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
    return Card(
      key: const Key('image_translate_no_methods'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.imageTranslateNoMethodsTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.imageTranslateNoMethodsBody,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  key: const Key('image_translate_providers_button'),
                  onPressed: () => context.go(AppRoutes.providers),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: Text(l10n.translateProvidersAction),
                ),
                TextButton(
                  key: const Key('image_translate_instances_button'),
                  onPressed: () => context.go(AppRoutes.instances),
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
