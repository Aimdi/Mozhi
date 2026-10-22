import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// A labelled on/off tool under the translation ("Check meaning",
/// "Insights", "Romanization", "Matching phrases"): an outlined pill
/// filter chip with an icon, selected (check mark, "selected" for screen
/// readers) while the tool is on.
///
/// [tooltip] says what a tap does ("Hide insights"); when it is the same as
/// [label] it is left out of the semantics so screen readers hear the name
/// once.
class TranslateToolChip extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool selected;

  /// Null disables the chip.
  final VoidCallback? onPressed;

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final onPressed = this.onPressed;
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: tooltip == label,
      // An outlined hairline pill (X topic).
      child: TranslatePills(
        child: FilterChip(
          focusNode: focusNode,
          avatar: Icon(icon),
          label: Text(label),
          selected: selected,
          onSelected: onPressed == null ? null : (_) => onPressed(),
        ),
      ),
    );
  }
}

/// One row of the "Tools" area under the translation: an icon, a label and
/// what the row does at its end, the one pattern of that area.
///
/// * An on/off tool ([selected] not null: "Check meaning", "Insights",
///   "Romanization", "Matching phrases") shows a check mark while it is on
///   and is a checkbox for screen readers.
/// * A row that unfolds its content under it ([expanded] not null:
///   "Alternatives", "Definitions") shows a chevron that turns, and tells
///   screen readers whether it is expanded.
/// * A row that [opens] another view ("Explain", "Compare engines") shows
///   a chevron pointing to the end.
///
/// At least 48 dp high. A null [onPressed] disables the row.
class TranslateToolRow extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected,
    this.expanded,
    this.opens = false,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String label;

  /// Null disables the row.
  final VoidCallback? onPressed;

  /// Whether an on/off tool is on; null for other rows.
  final bool? selected;

  /// Whether an unfolding row is open; null for other rows.
  final bool? expanded;

  /// Whether the row opens another view (a sheet, compare mode).
  final bool opens;

  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = selected ?? false;
    final expanded = this.expanded;
    final Widget? trailing;
    if (selected != null) {
      trailing = on ? Icon(Icons.check, color: scheme.primary, size: 20) : null;
    } else if (expanded != null) {
      trailing = AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: TranslateLayout.motion(context),
        curve: Curves.easeOutCubic,
        child: const Icon(Icons.expand_more),
      );
    } else if (opens) {
      trailing = const Icon(Icons.chevron_right);
    } else {
      trailing = null;
    }
    return MergeSemantics(
      child: Semantics(
        checked: selected,
        expanded: expanded,
        child: ListTile(
          focusNode: focusNode,
          minTileHeight: 48,
          minLeadingWidth: 24,
          horizontalTitleGap: 12,
          contentPadding: const EdgeInsetsDirectional.only(start: 8, end: 8),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          selected: on,
          enabled: onPressed != null,
          leading: Icon(icon, size: 22),
          title: Text(label, style: theme.textTheme.bodyLarge),
          trailing: trailing,
          onTap: onPressed,
        ),
      ),
    );
  }
}
