import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/usage/widgets/usage_format.dart';

/// A horizontal, rounded bar filled to [fraction] (clamped to 0–1).
///
/// Non-zero fractions always show a sliver so tiny usage stays visible.
class UsageBar extends StatelessWidget {
  const new({
    required this.fraction,
    this.color,
    this.trackColor,
    this.height = 8,
    this.semanticsLabel,
    super.key,
  });

  final double fraction;

  /// Fill colour; defaults to the primary colour.
  final Color? color;

  /// Background colour; defaults to `surfaceContainerHighest`.
  final Color? trackColor;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
    final radius = BorderRadius.circular(height / 2);
    return Semantics(
      label: semanticsLabel,
      container: semanticsLabel != null,
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          height: height,
          child: ColoredBox(
            color: trackColor ?? scheme.surfaceContainerHighest,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                widthFactor: value == 0 ? 0 : math.max(value, 0.015),
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color ?? scheme.primary,
                    borderRadius: radius,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small column chart of characters per month (oldest first) drawn with
/// [CustomPaint], with short month names below. The last month is
/// highlighted.
class UsageHistoryChart extends StatelessWidget {
  const new({
    required this.months,
    required this.values,
    this.height = 56,
    super.key,
  });

  /// The months shown, oldest first.
  final List<UsageMonth> months;

  /// Characters per month; same length as [months].
  final List<int> values;
  final double height;

  @override
  Widget build(BuildContext context) {
    assert(months.length == values.length, 'one value per month');
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = context.l10n.usageHistoryLabel(
      [
        for (var i = 0; i < months.length; i++)
          context.l10n.usageHistoryValue(
            context.usageMonthShort(months[i]),
            context.usageNumber(values[i]),
          ),
      ].join(', '),
    );
    return Semantics(
      label: label,
      container: true,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: height,
              child: CustomPaint(
                painter: UsageHistoryPainter(
                  values: values,
                  color: scheme.primary.withValues(alpha: 0.45),
                  highlightColor: scheme.primary,
                  baselineColor: scheme.outlineVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final month in months)
                  Expanded(
                    child: Text(
                      context.usageMonthShort(month),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints [values] as evenly spaced columns scaled to the largest value,
/// the last one in [highlightColor], on a [baselineColor] baseline.
class UsageHistoryPainter extends CustomPainter {
  const new({
    required this.values,
    required this.color,
    required this.highlightColor,
    required this.baselineColor,
  });

  final List<int> values;
  final Color color;
  final Color highlightColor;
  final Color baselineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = baselineColor
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      baseline,
    );
    if (values.isEmpty) return;
    final maxValue = values.fold(0, math.max);
    if (maxValue <= 0) return;
    final slot = size.width / values.length;
    final barWidth = math.min(slot * 0.6, 28).toDouble();
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value <= 0) continue;
      final barHeight = math.max(size.height * value / maxValue, 2).toDouble();
      final left = slot * i + (slot - barWidth) / 2;
      final rect = Rect.fromLTWH(
        left,
        size.height - barHeight,
        barWidth,
        barHeight,
      );
      final radius = Radius.circular(math.min(barWidth / 4, 6));
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect, topLeft: radius, topRight: radius),
        Paint()..color = i == values.length - 1 ? highlightColor : color,
      );
    }
  }

  @override
  bool shouldRepaint(UsageHistoryPainter oldDelegate) =>
      !listEquals(values, oldDelegate.values) ||
      color != oldDelegate.color ||
      highlightColor != oldDelegate.highlightColor ||
      baselineColor != oldDelegate.baselineColor;
}
