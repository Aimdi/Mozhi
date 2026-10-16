import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

/// Extra colours of the app's X-inspired look that [ColorScheme] has no
/// slot for: hairlines, secondary text and the action accents (like pink,
/// success green).
///
/// Registered on the app theme; [AppPalette.of] derives a matching palette
/// from the [ColorScheme] when a theme does not register one (tests).
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const new({
    required this.hairline,
    required this.secondaryText,
    required this.like,
    required this.success,
    required this.barBackground,
  });

  /// The palette for [scheme].
  factory fromScheme(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return AppPalette(
      hairline: dark ? const Color(0xFF2F3336) : const Color(0xFFEFF3F4),
      secondaryText: dark ? const Color(0xFF8B98A5) : const Color(0xFF536471),
      like: const Color(0xFFF91880),
      success: const Color(0xFF00BA7C),
      barBackground: scheme.surface.withValues(alpha: 0.85),
    );
  }

  /// 1 px separators between rows and around flat cards.
  final Color hairline;

  /// Metadata, timestamps, handles: quieter than body text.
  final Color secondaryText;

  /// Favourite / like accent.
  final Color like;

  /// Confirmations (copied, saved).
  final Color success;

  /// Translucent background of blurred top and bottom bars.
  final Color barBackground;

  /// The palette of the ambient theme.
  // A lookup, like Theme.of, not a way to construct a palette.
  // ignore: prefer_constructors_over_static_methods
  static AppPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppPalette>() ??
        AppPalette.fromScheme(theme.colorScheme);
  }

  @override
  AppPalette copyWith({
    Color? hairline,
    Color? secondaryText,
    Color? like,
    Color? success,
    Color? barBackground,
  }) => AppPalette(
    hairline: hairline ?? this.hairline,
    secondaryText: secondaryText ?? this.secondaryText,
    like: like ?? this.like,
    success: success ?? this.success,
    barBackground: barBackground ?? this.barBackground,
  );

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      hairline: Color.lerp(hairline, other.hairline, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      like: Color.lerp(like, other.like, t)!,
      success: Color.lerp(success, other.success, t)!,
      barBackground: Color.lerp(barBackground, other.barBackground, t)!,
    );
  }
}

/// A 1 px hairline separator in [AppPalette.hairline].
class Hairline extends StatelessWidget {
  const new({this.indent = 0, this.vertical = false, super.key});

  /// Start inset (horizontal hairlines only).
  final double indent;

  /// A vertical line instead of a horizontal one.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final color = AppPalette.of(context).hairline;
    if (vertical) return VerticalDivider(width: 1, thickness: 1, color: color);
    return Divider(height: 1, thickness: 1, indent: indent, color: color);
  }
}

/// Translucent, blurred chrome (top bars, bottom bars, sticky headers):
/// content scrolling underneath shows through frosted.
///
/// Draws a hairline on the [top] and/or [bottom] edge.
class BlurBar extends StatelessWidget {
  const new({
    required this.child,
    this.top = false,
    this.bottom = false,
    this.sigma = 16,
    super.key,
  });

  final Widget child;
  final bool top;
  final bool bottom;

  /// Blur strength; 0 skips the (costly) backdrop filter.
  final double sigma;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final side = BorderSide(color: palette.hairline);
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: palette.barBackground,
        border: Border(
          top: top ? side : BorderSide.none,
          bottom: bottom ? side : BorderSide.none,
        ),
      ),
      child: child,
    );
    if (sigma <= 0) return bar;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: bar,
      ),
    );
  }
}

/// A round "avatar" for a language: its short code on a colour picked from
/// the code, so a language always gets the same colour.
///
/// Decorative: excluded from semantics (the language name is always
/// spelled out next to it).
class LanguageAvatar extends StatelessWidget {
  const new({required this.code, this.size = 40, super.key});

  /// Language code (`en`, `pt-BR`, `auto`) or a custom target's text.
  final String code;

  /// Diameter in logical pixels.
  final double size;

  static const _hues = <double>[
    203, // X blue
    330,
    160,
    265,
    25,
    45,
    190,
    290,
    0,
    120,
  ];

  /// Up to two upper-case letters shown for [code].
  static String initials(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return '?';
    if (trimmed == 'auto') return '✦';
    final base = trimmed.split(RegExp('[-_ ]')).first;
    final letters = base.characters.take(2).toString();
    return letters.toUpperCase();
  }

  /// The stable background colour of [code] for [brightness].
  static Color colorFor(String code, Brightness brightness) {
    var hash = 0;
    for (final unit in code.toLowerCase().codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final hue = _hues[hash % _hues.length];
    return HSLColor.fromAHSL(
      1,
      hue,
      0.62,
      brightness == Brightness.dark ? 0.38 : 0.46,
    ).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorFor(code, theme.brightness);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Center(
            child: Text(
              initials(code),
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: size * 0.36,
                height: 1,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An X-style action: a quiet icon (with an optional count/label) that
/// takes its [activeColor] and "pops" when it becomes [active] (like,
/// copied, playing).
///
/// Always a 48 dp target with a [tooltip] (also its semantic label).
class XActionButton extends StatefulWidget {
  const new({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.activeIcon,
    this.active = false,
    this.activeColor,
    this.label,
    super.key,
  });

  final IconData icon;

  /// Icon while [active]; defaults to [icon].
  final IconData? activeIcon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  /// Colour while [active]; defaults to the scheme's primary.
  final Color? activeColor;

  /// Short text after the icon (a count, "Copied").
  final String? label;

  @override
  State<XActionButton> createState() => _XActionButtonState();
}

class _XActionButtonState extends State<XActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  @override
  void didUpdateWidget(XActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (!reduce) _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final enabled = widget.onPressed != null;
    final active = widget.active;
    final activeColor = widget.activeColor ?? theme.colorScheme.primary;
    final color = !enabled
        ? palette.secondaryText.withValues(alpha: 0.4)
        : active
        ? activeColor
        : palette.secondaryText;

    final icon = AnimatedBuilder(
      animation: _pop,
      builder: (context, child) {
        // 1 → 1.3 → 1 over the animation, an overshooting "pop".
        final t = _pop.value;
        final scale = 1 + 0.3 * math.sin(math.pi * t);
        return Transform.scale(scale: scale, child: child);
      },
      child: Icon(
        active ? (widget.activeIcon ?? widget.icon) : widget.icon,
        size: 20,
        color: color,
      ),
    );

    final label = widget.label;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        toggled: widget.activeIcon != null ? active : null,
        label: widget.tooltip,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: InkResponse(
          onTap: widget.onPressed,
          radius: 22,
          highlightColor: activeColor.withValues(alpha: 0.1),
          splashColor: activeColor.withValues(alpha: 0.16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                if (label != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// X's character counter: a small ring that fills as [count] approaches
/// [limit], turns amber in the last 10 % and red past the limit, and spells
/// out the remaining count near the end.
class CountRing extends StatelessWidget {
  const new({required this.count, required this.limit, super.key});

  final int count;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final remaining = limit - count;
    final ratio = limit <= 0 ? 0.0 : (count / limit).clamp(0.0, 1.0);
    final near = remaining <= limit * 0.1;
    final over = remaining < 0;
    final color = over
        ? theme.colorScheme.error
        : near
        ? const Color(0xFFFFD400)
        : theme.colorScheme.primary;
    final size = near ? 30.0 : 22.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: ratio,
              strokeWidth: 2.5,
              color: color,
              backgroundColor: palette.hairline,
            ),
          ),
          if (near)
            Text(
              '$remaining',
              textScaler: TextScaler.noScaling,
              style: theme.textTheme.labelSmall?.copyWith(
                color: over ? theme.colorScheme.error : palette.secondaryText,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }
}
