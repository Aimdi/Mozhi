import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';

/// A preset seed colour offered by [AccentColorPicker].
class AccentColorOption {
  const new(this.argb, this.label);

  final int argb;
  final String Function(AppLocalizations l10n) label;

  static final options = <AccentColorOption>[
    AccentColorOption(0xFF3F51B5, (l10n) => l10n.settingsColorIndigo),
    AccentColorOption(0xFF1E6FD9, (l10n) => l10n.settingsColorBlue),
    AccentColorOption(0xFF00897B, (l10n) => l10n.settingsColorTeal),
    AccentColorOption(0xFF43A047, (l10n) => l10n.settingsColorGreen),
    AccentColorOption(0xFF7C8B3A, (l10n) => l10n.settingsColorOlive),
    AccentColorOption(0xFFFFB300, (l10n) => l10n.settingsColorAmber),
    AccentColorOption(0xFFF4511E, (l10n) => l10n.settingsColorOrange),
    AccentColorOption(0xFFD32F2F, (l10n) => l10n.settingsColorRed),
    AccentColorOption(0xFFD81B60, (l10n) => l10n.settingsColorPink),
    AccentColorOption(0xFF8E24AA, (l10n) => l10n.settingsColorPurple),
  ];
}

/// Row of round colour swatches (48 dp targets) for the seed colour.
class AccentColorPicker extends StatelessWidget {
  const new({required this.selected, required this.onSelected, super.key});

  /// Currently selected ARGB value.
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final option in AccentColorOption.options)
          _Swatch(
            color: Color(option.argb),
            label: option.label(l10n),
            selected: option.argb == selected,
            onTap: () => onSelected(option.argb),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const new({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    // `excludeSemantics` drops the InkResponse's tap action, so the outer
    // node has to provide it for TalkBack, switch access and web.
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: SizedBox.square(
            dimension: 48,
            child: Center(
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? colors.onSurface : colors.outlineVariant,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check, size: 20, color: onColor)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
