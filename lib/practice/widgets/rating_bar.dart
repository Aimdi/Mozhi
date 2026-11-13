import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/widgets/practice_texts.dart';

/// The four rating buttons, each with when the card would come back
/// ([intervals]) and its keyboard key (1 to 4) in the tooltip. The
/// [suggested] rating (from a spoken or typed answer) is filled and
/// marked "Suggested"; the user still chooses.
class RatingBar extends StatelessWidget {
  const new({
    required this.intervals,
    required this.onRate,
    this.suggested,
    super.key,
  });

  final Map<FsrsRating, Duration> intervals;
  final ValueChanged<FsrsRating> onRate;
  final FsrsRating? suggested;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        for (final rating in FsrsRating.values) ...[
          if (rating != FsrsRating.again) const SizedBox(width: 8),
          Expanded(
            child: _RatingButton(
              key: ValueKey('practice_rate_${rating.name}'),
              label: practiceRatingLabel(l10n, rating),
              interval: switch (intervals[rating]) {
                final interval? => practiceIntervalText(l10n, interval),
                null => '',
              },
              shortcut: '${rating.grade}',
              suggested: rating == suggested,
              suggestedLabel: l10n.practiceRatingSuggested,
              again: rating == FsrsRating.again,
              onPressed: () => onRate(rating),
            ),
          ),
        ],
      ],
    );
  }
}

class _RatingButton extends StatelessWidget {
  const new({
    required this.label,
    required this.interval,
    required this.shortcut,
    required this.suggested,
    required this.suggestedLabel,
    required this.onPressed,
    this.again = false,
    super.key,
  });

  final String label;
  final String interval;
  final String shortcut;
  final bool suggested;
  final String suggestedLabel;
  final bool again;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final semantics = [
      if (interval.isEmpty)
        label
      else
        l10n.practiceRatingSemantics(label, interval),
      if (suggested) suggestedLabel,
    ].join(', ');
    final colors = theme.colorScheme;
    // Explicit colours: the looks' filled-button themes (an accent or an
    // inverse fill) would otherwise also paint the tonal buttons, and the
    // secondary interval text and the red "Again" would not read on them.
    final background = suggested ? colors.primary : colors.surfaceContainerHigh;
    final foreground = suggested ? colors.onPrimary : colors.onSurface;
    final labelColor = again && !suggested
        ? accentWithContrast(
            colors.error,
            background,
            minContrast: kTextContrast,
            darken: theme.brightness == Brightness.light,
          )
        : foreground;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w700, color: labelColor),
        ),
        if (interval.isNotEmpty)
          Text(
            interval,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: foreground),
          ),
      ],
    );
    const padding = EdgeInsets.symmetric(horizontal: 4, vertical: 10);
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 56)),
      padding: const WidgetStatePropertyAll(padding),
      backgroundColor: WidgetStatePropertyAll(background),
      foregroundColor: WidgetStatePropertyAll(foreground),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.pressed)
            ? foreground.withValues(alpha: 0.12)
            : states.any(
                (s) => s == WidgetState.hovered || s == WidgetState.focused,
              )
            ? foreground.withValues(alpha: 0.08)
            : null,
      ),
      side: WidgetStatePropertyAll(
        BorderSide(color: suggested ? colors.primary : colors.outline),
      ),
    );
    return Tooltip(
      message: '$label ($shortcut)',
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: semantics,
        excludeSemantics: true,
        onTap: onPressed,
        child: FilledButton(onPressed: onPressed, style: style, child: content),
      ),
    );
  }
}
