import 'package:material_ui/material_ui.dart';

/// A labelled on/off tool under the translation ("Check meaning",
/// "Insights", "Romanization", "Matching phrases"): a filter chip with an
/// icon, selected (check mark, "selected" for screen readers) while the
/// tool is on.
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
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: tooltip == label,
      // Flat chips sit on a canvas-coloured Material: let the card's
      // surface show through instead.
      child: Theme(
        data: theme.copyWith(canvasColor: Colors.transparent),
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
