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
///
/// Use [SettingsIcon] for the leading icons of the tiles inside.
class SettingsSection extends StatelessWidget {
  const new({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 10),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Card.filled(
            margin: EdgeInsets.zero,
            color: colors.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }
}

/// A settings tile's leading icon on a soft tinted square.
///
/// Tinted with the primary colour, or with [color] (e.g. the error colour
/// for destructive actions). In a disabled tile, which greys out its icons
/// through the [IconTheme], it takes that grey instead.
class SettingsIcon extends StatelessWidget {
  const new(this.icon, {this.color, super.key});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final inherited = IconTheme.of(context).color;
    // An enabled ListTile gives its icons onSurfaceVariant.
    final enabled = inherited == null || inherited == colors.onSurfaceVariant;
    final foreground = enabled ? color ?? colors.primary : inherited;
    return SizedBox.square(
      dimension: 40,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 22, color: foreground),
      ),
    );
  }
}

/// A separator before destructive actions at the end of a
/// [SettingsSection].
class SettingsDangerDivider extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 13,
    indent: 16,
    endIndent: 16,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

/// WCAG contrast ratio between two opaque colours (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// A small rounded label with an optional icon, tinted with [color].
///
/// The background is an opaque tint of [color] and the label is [color]
/// darkened (light theme) or lightened (dark theme) towards `onSurface`
/// until it reaches at least [minContrast] against that background, so the
/// badge stays readable on any card it sits on (WCAG 1.4.3).
class StatusBadge extends StatelessWidget {
  const new({
    required this.label,
    required this.color,
    this.icon,
    this.semanticsLabel,
    super.key,
  });

  final String label;

  /// Accent the badge is tinted with.
  final Color color;
  final IconData? icon;

  /// Read by screen readers instead of [label], e.g. to spell out what a
  /// colour means.
  final String? semanticsLabel;

  /// Minimum text contrast; a little above the 4.5:1 AA threshold so that
  /// 8-bit rounding never drops below it.
  static const minContrast = 4.6;

  static final Map<(int, int, int), ({Color background, Color foreground})>
  _cache = {};

  /// The opaque background and the text/icon colour of a badge tinted with
  /// [color] in [scheme].
  static ({Color background, Color foreground}) colorsFor(
    Color color,
    ColorScheme scheme,
  ) {
    final key = (
      color.toARGB32(),
      scheme.surfaceContainerLow.toARGB32(),
      scheme.onSurface.toARGB32(),
    );
    return _cache[key] ??= () {
      final opaque = color.withValues(alpha: 1);
      final background = Color.alphaBlend(
        opaque.withValues(alpha: 0.14),
        scheme.surfaceContainerLow,
      );
      var foreground = opaque;
      for (var step = 1; step <= 10; step++) {
        if (contrastRatio(foreground, background) >= minContrast) break;
        foreground = Color.lerp(opaque, scheme.onSurface, step / 10)!;
      }
      return (background: background, foreground: foreground);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (:background, :foreground) = colorsFor(color, theme.colorScheme);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: foreground,
      fontWeight: FontWeight.w600,
    );
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: foreground),
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
      ),
    );
  }
}

/// Semantic status colours that read well in light and dark themes.
extension StatusColors on ColorScheme {
  /// At least 5:1 against every light surface role.
  Color get success => brightness == Brightness.dark
      ? const Color(0xFF8FD19E)
      : const Color(0xFF146C2E);

  Color get warning => brightness == Brightness.dark
      ? const Color(0xFFFFC870)
      : const Color(0xFF8A5A00);
}
