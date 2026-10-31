import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

/// A dashed 1 px rule of the terminal look: under its top bar and above
/// its navigation bar (horizontal, the default), or beside its navigation
/// rail ([axis] vertical).
///
/// Its colour is [color], else the theme's hairline
/// ([AppPalette.hairline]). Decorative: nothing for screen readers.
class TerminalRule extends StatelessWidget {
  const new({
    this.axis = Axis.horizontal,
    this.color,
    this.dash = 4,
    this.gap = 3,
    super.key,
  });

  /// The direction of the line.
  final Axis axis;

  /// The colour of the dashes; null: [AppPalette.hairline].
  final Color? color;

  /// Length of a dash (logical pixels).
  final double dash;

  /// Space between two dashes (logical pixels).
  final double gap;

  /// Thickness of the line.
  static const double thickness = 1;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    return SizedBox(
      width: horizontal ? double.infinity : thickness,
      height: horizontal ? thickness : double.infinity,
      child: CustomPaint(
        painter: TerminalRulePainter(
          color: color ?? AppPalette.of(context).hairline,
          axis: axis,
          dash: dash,
          gap: gap,
        ),
      ),
    );
  }
}

/// Paints the dashes of a [TerminalRule] along [axis], from the start of
/// the box to its end.
class TerminalRulePainter extends CustomPainter {
  const new({
    required this.color,
    this.axis = Axis.horizontal,
    this.dash = 4,
    this.gap = 3,
  });

  final Color color;
  final Axis axis;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final horizontal = axis == Axis.horizontal;
    final length = horizontal ? size.width : size.height;
    final thickness = horizontal ? size.height : size.width;
    if (length <= 0 || thickness <= 0 || dash <= 0) return;
    final step = dash + (gap < 0 ? 0 : gap);
    for (var start = 0.0; start < length; start += step) {
      final end = (start + dash).clamp(0, length).toDouble();
      canvas.drawRect(
        horizontal
            ? Rect.fromLTRB(start, 0, end, thickness)
            : Rect.fromLTRB(0, start, thickness, end),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(TerminalRulePainter oldDelegate) =>
      color != oldDelegate.color ||
      axis != oldDelegate.axis ||
      dash != oldDelegate.dash ||
      gap != oldDelegate.gap;
}
