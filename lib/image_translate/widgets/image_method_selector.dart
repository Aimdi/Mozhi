import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Choice chips for the available methods, with a short description of the
/// selected one. Hidden when no method is available.
class ImageMethodSelector extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final (methods, selected) = context
        .select<
          ImageTranslateCubit,
          (List<ImageTranslateMethod>, ImageTranslateMethod?)
        >((cubit) => (cubit.state.methods, cubit.state.method));
    if (methods.isEmpty) return const SizedBox.shrink();
    final cubit = context.read<ImageTranslateCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.imageTranslateMethodLabel,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final method in methods)
              ChoiceChip(
                key: Key('image_translate_method_${method.id}'),
                avatar: Icon(imageMethodIcon(method.kind)),
                showCheckmark: false,
                label: Text(imageMethodLabel(l10n, method)),
                selected: method == selected,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => unawaited(cubit.selectMethod(method)),
              ),
          ],
        ),
        if (selected != null) ...[
          const SizedBox(height: 4),
          Text(
            imageMethodDescription(l10n, selected.kind),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.of(context).secondaryText,
            ),
          ),
        ],
      ],
    );
  }
}
