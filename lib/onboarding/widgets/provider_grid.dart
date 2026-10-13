import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:translation_repository/translation_repository.dart';

/// Adaptive grid of [AiProviderPreset]s (1-4 columns, equal-height rows).
class ProviderGrid extends StatelessWidget {
  const new({
    required this.presets,
    required this.onSelected,
    this.selectedId,
    super.key,
  });

  final List<AiProviderPreset> presets;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  static const _minTileWidth = 200.0;
  static const _spacing = 12.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / _minTileWidth).floor().clamp(
          1,
          4,
        );
        final rows = <Widget>[];
        for (var start = 0; start < presets.length; start += columns) {
          final row = presets.skip(start).take(columns).toList();
          rows.add(
            Padding(
              padding: EdgeInsets.only(top: start == 0 ? 0 : _spacing),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < columns; i++) ...[
                      if (i > 0) const SizedBox(width: _spacing),
                      Expanded(
                        child: i < row.length
                            ? ProviderCard(
                                key: ValueKey('preset-${row[i].id}'),
                                preset: row[i],
                                selected: row[i].id == selectedId,
                                onTap: () => onSelected(row[i].id),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

/// A selectable preset: name, "Local" badge and description.
class ProviderCard extends StatelessWidget {
  const new({
    required this.preset,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AiProviderPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Card.outlined(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: selected ? colors.secondaryContainer : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preset.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_circle,
                          size: 20,
                          color: colors.primary,
                        ),
                    ],
                  ),
                  if (preset.isLocal) ...[
                    const SizedBox(height: 6),
                    OnboardingBadge(
                      label: l10n.onboardingAiLocalBadge,
                      color: colors.onboardingSuccess,
                      icon: Icons.lock_outline,
                    ),
                  ],
                  if (preset.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      preset.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: selected
                            ? colors.onSecondaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
