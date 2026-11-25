import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Marks a translation (or engine) as produced on the device.
///
/// Shows a small "Offline" label, or only an icon when [compact].
class OfflineEngineBadge extends StatelessWidget {
  const new({super.key, this.compact = false});

  final bool compact;

  static const IconData icon = Icons.offline_bolt_outlined;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final color = Theme.of(context).colorScheme.tertiary;
    return Tooltip(
      message: l10n.offlineBadgeTooltip,
      child: compact
          ? Icon(icon, size: 18, color: color, semanticLabel: l10n.offlineBadge)
          : StatusBadge(label: l10n.offlineBadge, color: color, icon: icon),
    );
  }
}
