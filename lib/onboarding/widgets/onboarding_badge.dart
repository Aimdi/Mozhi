import 'package:material_ui/material_ui.dart';

/// Status colours used by the onboarding (readable in light and dark).
extension OnboardingColors on ColorScheme {
  Color get onboardingSuccess => brightness == Brightness.dark
      ? const Color(0xFF8FD19E)
      : const Color(0xFF1B7A35);

  Color get onboardingWarning => brightness == Brightness.dark
      ? const Color(0xFFFFC870)
      : const Color(0xFF8A5A00);
}

/// A small rounded label with an optional icon, tinted with [color].
class OnboardingBadge extends StatelessWidget {
  const new({required this.label, required this.color, this.icon, super.key});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600);
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
