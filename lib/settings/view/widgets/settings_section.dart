import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

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

/// A titled group of settings in the X style: a bold section heading,
/// plain rows and a hairline that closes the group (no card, no tint).
///
/// Without a [title] (the only group of a page, which its app bar names)
/// the rows start right away. A [badge] (e.g. "Advanced") follows the
/// title and is read with it. Use [SettingsIcon] for the leading icons of
/// the tiles inside.
class SettingsSection extends StatelessWidget {
  const new({
    required this.children,
    this.title,
    this.badge,
    this.divider = true,
    super.key,
  });

  final String? title;
  final List<Widget> children;

  /// Whether a hairline closes the group (none for the last group of a
  /// page).
  final bool divider;

  /// A short label shown next to the title.
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = this.title;
    if (title == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...children,
            if (divider) ...[const SizedBox(height: 8), const Hairline()],
          ],
        ),
      );
    }
    final heading = Text(
      title,
      style: theme.textTheme.titleLarge?.copyWith(
        color: theme.colorScheme.onSurface,
        fontWeight: FontWeight.w800,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8),
            // Its own node: without the old card around the rows, a plain
            // header flag would merge the rows into the heading.
            child: Semantics(
              container: true,
              header: true,
              child: switch (badge) {
                null => heading,
                final badge => Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    heading,
                    StatusBadge(
                      label: badge,
                      color: theme.colorScheme.tertiary,
                    ),
                  ],
                ),
              },
            ),
          ),
          ...children,
          if (divider) ...[const SizedBox(height: 8), const Hairline()],
        ],
      ),
    );
  }
}

/// A settings row's leading icon: a plain outline icon in the secondary
/// text colour, or in [color] (e.g. the error colour for destructive
/// actions). In a disabled tile, which greys out its icons through the
/// [IconTheme], it takes that grey instead.
class SettingsIcon extends StatelessWidget {
  const new(this.icon, {this.color, super.key});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final secondary = AppPalette.of(context).secondaryText;
    final inherited = IconTheme.of(context).color;
    // A disabled ListTile greys its icons out with a translucent colour.
    final enabled = inherited == null || inherited.a >= 0.5;
    final foreground = enabled ? color ?? secondary : inherited;
    return Icon(icon, size: 24, color: foreground);
  }
}

/// A hairline before destructive actions at the end of a
/// [SettingsSection].
class SettingsDangerDivider extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 6),
    child: Hairline(),
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
          borderRadius: const BorderRadius.all(
            Radius.circular(AppRadius.badge),
          ),
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
