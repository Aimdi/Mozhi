import 'package:material_ui/material_ui.dart';

/// A chip showing the current [value] of a proofreading option (the
/// correction level, the style); tapping it opens a menu of [values].
class QuickImproveOptionChip<T extends Enum> extends StatelessWidget {
  const new({
    required this.value,
    required this.values,
    required this.labelOf,
    required this.tooltip,
    required this.icon,
    required this.keyPrefix,
    this.onSelected,
    super.key,
  });

  final T value;
  final List<T> values;
  final String Function(T value) labelOf;

  /// Names the option and its value (for the tooltip and screen readers).
  final String tooltip;
  final IconData icon;

  /// Prefix of the keys of the chip (`<prefix>_chip`) and its menu items
  /// (`<prefix>_<name>`).
  final String keyPrefix;

  /// Picks a value; null disables the chip.
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSelected = this.onSelected;
    return MenuAnchor(
      menuChildren: [
        for (final option in values)
          MenuItemButton(
            key: Key('${keyPrefix}_${option.name}'),
            trailingIcon: option == value
                ? Icon(Icons.check, color: theme.colorScheme.primary)
                : null,
            onPressed: onSelected == null ? null : () => onSelected(option),
            child: Text(labelOf(option)),
          ),
      ],
      builder: (context, controller, _) => ActionChip(
        key: Key('${keyPrefix}_chip'),
        tooltip: tooltip,
        avatar: Icon(icon),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                labelOf(value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
        onPressed: onSelected == null
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
