import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Horizontal padding that keeps content at most [maxWidth] wide and
/// centered, with a 16 dp gutter on small screens.
EdgeInsets centeredPadding(
  double availableWidth, {
  double maxWidth = 720,
  double top = 8,
  double bottom = 32,
}) {
  final horizontal = math.max(16, (availableWidth - maxWidth) / 2).toDouble();
  return EdgeInsets.fromLTRB(horizontal, top, horizontal, bottom);
}

/// A titled group of settings rendered as a calm, rounded card.
class SettingsSection extends StatelessWidget {
  const new({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          Card.filled(
            margin: EdgeInsets.zero,
            color: theme.colorScheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

/// A small rounded label with an optional icon, tinted with [color].
class StatusBadge extends StatelessWidget {
  const new({required this.label, required this.color, this.icon, super.key});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: color, fontWeight: FontWeight.w600);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Semantic status colours that read well in light and dark themes.
extension StatusColors on ColorScheme {
  Color get success => brightness == Brightness.dark
      ? const Color(0xFF8FD19E)
      : const Color(0xFF1B7A35);

  Color get warning => brightness == Brightness.dark
      ? const Color(0xFFFFC870)
      : const Color(0xFF8A5A00);
}
