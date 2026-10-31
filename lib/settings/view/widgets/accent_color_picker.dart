import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';

/// A preset seed colour offered by [AccentColorPicker].
class AccentColorOption {
  const new(this.argb, this.label);

  final int argb;
  final String Function(AppLocalizations l10n) label;

  /// X's accents first (blue is the default) with Lavender next to Purple,
  /// then a few classics so a previously picked colour stays selectable.
  static final options = <AccentColorOption>[
    AccentColorOption(0xFF1D9BF0, (l10n) => l10n.settingsColorBlue),
    AccentColorOption(0xFFFFD400, (l10n) => l10n.settingsColorYellow),
    AccentColorOption(0xFFF91880, (l10n) => l10n.settingsColorPink),
    AccentColorOption(0xFF7856FF, (l10n) => l10n.settingsColorPurple),
    // A soft pastel violet, like Kagi Translate's accent. Too light for
    // text on white: the light theme darkens it (see `appColorScheme`).
    AccentColorOption(0xFFC4B5FD, (l10n) => l10n.settingsColorLavender),
    AccentColorOption(0xFFFF7A00, (l10n) => l10n.settingsColorOrange),
    AccentColorOption(0xFF00BA7C, (l10n) => l10n.settingsColorGreen),
    AccentColorOption(0xFF00897B, (l10n) => l10n.settingsColorTeal),
    AccentColorOption(0xFFF4212E, (l10n) => l10n.settingsColorRed),
    AccentColorOption(0xFF3F51B5, (l10n) => l10n.settingsColorIndigo),
  ];

  /// The accents of the terminal look ([kTerminalAccents], amber first).
  static final terminalOptions = <AccentColorOption>[
    AccentColorOption(kTerminalAccents[0], (l10n) => l10n.settingsColorAmber),
    AccentColorOption(kTerminalAccents[1], (l10n) => l10n.settingsColorGreen),
    AccentColorOption(kTerminalAccents[2], (l10n) => l10n.settingsColorCyan),
    AccentColorOption(kTerminalAccents[3], (l10n) => l10n.settingsColorPink),
  ];
}

/// Row of colour swatches (48 dp targets) for the seed colour, or for
/// the terminal accent with [AccentColorOption.terminalOptions]: round,
/// square in the terminal look ([AppLook]). The selected one has a check
/// mark, so the choice is not shown by colour alone.
class AccentColorPicker extends StatelessWidget {
  const new({
    required this.selected,
    required this.onSelected,
    this.options,
    super.key,
  });

  /// Currently selected ARGB value.
  final int selected;
  final ValueChanged<int> onSelected;

  /// The colours offered ([AccentColorOption.options] when null).
  final List<AccentColorOption>? options;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final option in options ?? AccentColorOption.options)
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
    final square = AppLook.of(context).isTerminal;
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
          highlightShape: square ? BoxShape.rectangle : BoxShape.circle,
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
                  shape: square ? BoxShape.rectangle : BoxShape.circle,
                  border: Border.all(
                    color: selected ? colors.onSurface : colors.outline,
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
