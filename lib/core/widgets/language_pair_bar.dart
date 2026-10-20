import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

/// One language of a [LanguagePairBar]: the name shown ([label]), what
/// screen readers hear instead ([semanticLabel], e.g. "Translate into
/// French"), the [tooltip] (else [label]) and an optional accent [icon]
/// before the name. [onPressed] (usually opening a picker) null disables
/// the button.
@immutable
class LanguagePairSide {
  const new({
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    this.tooltip,
    this.icon,
    this.key,
  });

  /// The key of the language's button.
  final Key? key;
  final String label;
  final String semanticLabel;
  final String? tooltip;
  final IconData? icon;
  final VoidCallback? onPressed;
}

/// The languages of a screen in the look of the translate screen's
/// language bar: a hairline-outlined pill ([ComposerBar]) with the
/// [source] and [target] buttons (the name and a chevron, the target's a
/// little bolder) around a [middle] (usually a [LanguageSwapButton], a
/// [LanguagePairArrow] where the languages cannot be swapped). [leading]
/// and [trailing] go before and after them, set off by thin dividers
/// (e.g. an options button, and the go button of the screen,
/// `ComposerGoButton`).
///
/// The two buttons share the width: half each while both names fit
/// ([languagePairWidths]), otherwise the shorter one keeps its width and
/// the longer one gets the rest.
class LanguagePairBar extends StatelessWidget {
  const new({
    required this.source,
    required this.target,
    this.middle = const LanguagePairArrow(),
    this.leading = const [],
    this.trailing = const [],
    super.key,
  });

  final LanguagePairSide source;
  final LanguagePairSide target;

  /// Between the two languages; [middleWidth] wide.
  final Widget middle;
  final List<Widget> leading;
  final List<Widget> trailing;

  /// Width of the slot of [middle] (an icon button's).
  static const double middleWidth = 48;

  @override
  Widget build(BuildContext context) {
    return ComposerBar(
      children: [
        ...leading,
        Expanded(
          child: _LanguagePair(source: source, target: target, middle: middle),
        ),
        ...trailing,
      ],
    );
  }
}

/// Widths of two language buttons sharing [width], whose own widths are
/// [start] and [end]: half each while both fit in half; otherwise the
/// narrower one keeps its own width (when it fits in half) and the wider
/// one gets the rest; half each when neither fits.
(double, double) languagePairWidths(double width, double start, double end) {
  final available = math.max(0, width).toDouble();
  final half = available / 2;
  if (start <= half && end <= half) return (half, half);
  if (start <= half) return (start, available - start);
  if (end <= half) return (available - end, end);
  return (half, half);
}

class _LanguagePair extends StatelessWidget {
  const new({required this.source, required this.target, required this.middle});

  final LanguagePairSide source;
  final LanguagePairSide target;
  final Widget middle;

  /// Width of a button around its name: padding, the chevron and gaps.
  static const double _chrome = 30;

  /// Extra width of a button with an icon before the name.
  static const double _iconChrome = 24;

  @override
  Widget build(BuildContext context) {
    final style = _LanguageButton.labelStyle(context, target: false);
    final targetStyle = _LanguageButton.labelStyle(context, target: true);
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double widthOf(LanguagePairSide side, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: side.label, style: style),
        textDirection: direction,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width + _chrome + (side.icon == null ? 0 : _iconChrome);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final (sourceWidth, targetWidth) = languagePairWidths(
          constraints.maxWidth - LanguagePairBar.middleWidth,
          widthOf(source, style),
          widthOf(target, targetStyle),
        );
        return Row(
          children: [
            SizedBox(
              width: sourceWidth,
              child: _LanguageButton(side: source),
            ),
            SizedBox(
              width: LanguagePairBar.middleWidth,
              child: Center(child: middle),
            ),
            SizedBox(
              width: targetWidth,
              child: _LanguageButton(side: target, target: true),
            ),
          ],
        );
      },
    );
  }
}

/// A language of the [LanguagePairBar]: the name and a chevron, on the bar
/// without an outline of its own. Screen readers hear the side's semantic
/// label instead of the visible name.
class _LanguageButton extends StatelessWidget {
  const new({required this.side, this.target = false});

  final LanguagePairSide side;

  /// Whether this is the target language (bolder).
  final bool target;

  /// The style of the name (the translate screen's language bar's).
  static TextStyle? labelStyle(BuildContext context, {required bool target}) =>
      Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: target ? FontWeight.w800 : FontWeight.w700);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary = AppPalette.of(context).secondaryText;
    final enabled = side.onPressed != null;
    final icon = side.icon;
    return Tooltip(
      message: side.tooltip ?? side.label,
      excludeFromSemantics: true,
      child: TextButton(
        key: side.key,
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.only(start: 8, end: 2),
          foregroundColor: scheme.onSurface,
          // The colour comes from the button (greyed out while disabled).
          textStyle: labelStyle(context, target: target),
        ),
        onPressed: side.onPressed,
        child: Semantics(
          label: side.semanticLabel,
          // Hides only the visible name, not the button's actions.
          excludeSemantics: true,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 18,
                  color: enabled
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.38),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  side.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more,
                size: 16,
                color: enabled ? secondary : secondary.withValues(alpha: 0.38),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The swap button of a [LanguagePairBar] (the translate screen's): an
/// accent ⇄ that turns half a turn and ticks (a selection haptic) on each
/// swap; [onPressed] null disables it. Its accessible name is [tooltip].
///
/// An [onLongPress] (e.g. the recent language pairs) works while disabled
/// too; screen readers hear [longPressHint] for it, and the tooltip then
/// shows on hover and focus only.
class LanguageSwapButton extends StatefulWidget {
  const new({
    required this.tooltip,
    required this.onPressed,
    this.onLongPress,
    this.longPressHint,
    super.key,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final String? longPressHint;

  @override
  State<LanguageSwapButton> createState() => _LanguageSwapButtonState();
}

class _LanguageSwapButtonState extends State<LanguageSwapButton> {
  /// Turns of the icon: half a turn per swap.
  double _turns = 0;

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed;
    final onLongPress = widget.onLongPress;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final button = IconButton(
      tooltip: onLongPress == null ? widget.tooltip : null,
      color: Theme.of(context).colorScheme.primary,
      onPressed: onPressed == null
          ? null
          : () {
              Haptics.selection(context);
              setState(() => _turns += 0.5);
              onPressed();
            },
      onLongPress: onLongPress,
      icon: AnimatedRotation(
        turns: _turns,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 250),
        curve: Curves.easeInOutCubic,
        child: const Icon(Icons.swap_horiz),
      ),
    );
    if (onLongPress == null) return button;
    final withHint = MergeSemantics(
      child: Semantics(
        onLongPressHint: widget.longPressHint,
        child: Tooltip(
          message: widget.tooltip,
          triggerMode: TooltipTriggerMode.manual,
          child: button,
        ),
      ),
    );
    if (onPressed != null) return withHint;
    // A disabled button ignores long presses.
    return GestureDetector(
      excludeFromSemantics: true,
      onLongPress: onLongPress,
      child: withHint,
    );
  }
}

/// The middle of a [LanguagePairBar] whose languages cannot be swapped: a
/// quiet arrow from the source to the target (mirrored right to left),
/// left out of semantics.
class LanguagePairArrow extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Icon(
        Icons.arrow_forward,
        size: 18,
        color: AppPalette.of(context).secondaryText,
      ),
    );
  }
}

/// The middle of a [LanguagePairBar] while the languages load: a small
/// progress ring (decorative; the screen says what is loading).
class LanguagePairProgress extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          backgroundColor: AppPalette.of(context).hairline,
        ),
      ),
    );
  }
}
