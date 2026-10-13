import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// A section title with a muted "AI-generated" label on the far end; wraps
/// below the title when space is tight (narrow screens, large text).
class AiGeneratedHeader extends StatelessWidget {
  const AiGeneratedHeader({required this.title, this.icon, this.style, super.key});

  final String title;
  final IconData? icon;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, color: muted, size: 20),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Semantics(
                  header: true,
                  child: Text(title, style: style ?? theme.textTheme.titleSmall),
                ),
              ),
            ],
          ),
          Text(
            context.l10n.translateAiGenerated,
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}
