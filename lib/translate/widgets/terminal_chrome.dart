import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

/// Text styles of the terminal look's decorations (the font family and
/// colours come from the theme).
abstract final class TerminalStyles {
  /// Small labels: `stdin`, `stdout`, `$ history --tail 3` (12, secondary).
  static TextStyle? label(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppPalette.of(context).secondaryText,
        height: 1.3,
      );

  /// The accent `>` prompt before the input (18 w700).
  static TextStyle? prompt(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        height: 1.45,
        color: Theme.of(context).colorScheme.primary,
      );

  /// The text of the small tool buttons (`cam`, `doc`: 12 w500).
  static TextStyle? tool(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontSize: 12, fontWeight: FontWeight.w500);
}

/// CLI decoration of the terminal look (`stdin`, `--from`, `run ⏎`, `//`):
/// English in every locale, always left to right, on one line and hidden
/// from screen readers (a localized label says the same).
class TerminalGlyph extends StatelessWidget {
  const new(this.text, {this.style, super.key});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Text(
        text,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: style,
      ),
    );
  }
}

/// A box of the terminal look (the `stdin` input, the `stdout` result): a
/// 1 px hairline border, the raised panel colour, 14 dp padding and the
/// small [label] above [child].
///
/// While not [show]n it draws nothing but [child] (no box, no label, no
/// padding), with [child] in the same place of the tree, so it keeps its
/// state when the box comes and goes.
class TerminalPanel extends StatelessWidget {
  const new({
    required this.label,
    required this.child,
    this.show = true,
    super.key,
  });

  /// The CLI word above [child] (decoration: hidden from screen readers).
  final String label;
  final Widget child;

  /// Whether the box and its label are drawn.
  final bool show;

  /// Inner padding of the box.
  static const double padding = 14;

  /// Space between the label and [child].
  static const double labelGap = 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    return DecoratedBox(
      decoration: show
          ? BoxDecoration(
              color: scheme.surfaceContainer,
              border: Border.all(color: palette.hairline),
            )
          : const BoxDecoration(),
      child: Padding(
        padding: EdgeInsets.all(show ? padding : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (show) ...[
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TerminalGlyph(
                  label,
                  key: ValueKey('terminal_panel_label:$label'),
                  style: TerminalStyles.label(context),
                ),
              ),
              const SizedBox(height: labelGap),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// The square 1 px hairline frame of the terminal look's small tool
/// buttons, drawn [inset] inside [child] (a 48 dp touch target shows a
/// 40 dp box, like an icon button's own). Decoration only: [child] keeps
/// its size, actions and semantics.
class TerminalFrame extends StatelessWidget {
  const new({required this.child, this.inset = 4, super.key});

  final Widget child;

  /// Space between the edge of [child] and the frame.
  final double inset;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _FramePainter(
        color: AppPalette.of(context).hairline,
        inset: inset,
      ),
      child: child,
    );
  }
}

class _FramePainter extends CustomPainter {
  const new({required this.color, required this.inset});

  final Color color;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(inset + 0.5);
    if (rect.width <= 0 || rect.height <= 0) return;
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      color != oldDelegate.color || inset != oldDelegate.inset;
}

/// A small text tool button of the terminal look (`cam`, `doc`): the short
/// [text] is decoration; screen readers hear [label] (the localized name
/// of the tool), and pointing at it shows [label] too.
class TerminalTextButton extends StatelessWidget {
  const new({
    required this.text,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String text;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TerminalFrame(
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: const RoundedRectangleBorder(),
            foregroundColor: scheme.onSurface,
            backgroundColor: Colors.transparent,
            textStyle: TerminalStyles.tool(context),
          ),
          onPressed: onPressed,
          // The button keeps its own node (tap, focus, enabled state); the
          // visible short word gives way to the localized name.
          child: Semantics(
            label: label,
            excludeSemantics: true,
            child: TerminalGlyph(text),
          ),
        ),
      ),
    );
  }
}

/// The `●` of the terminal look (before the engine name), in [color].
/// Decoration: hidden from screen readers.
class TerminalGlyphDot extends StatelessWidget {
  const new({required this.color, super.key});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return TerminalGlyph(
      '●',
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(fontSize: 13, color: color),
    );
  }
}
