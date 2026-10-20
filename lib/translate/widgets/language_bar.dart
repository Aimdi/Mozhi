import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/detection_chips.dart';
import 'package:mozhi/translate/widgets/go_button.dart';
import 'package:mozhi/translate/widgets/language_picker_sheet.dart';
import 'package:mozhi/translate/widgets/options_sheet.dart';
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';

/// Opens the language picker for the source ([source]) or target language
/// and applies the choice. [autofocusSearch] focuses the search field
/// (keyboard shortcut: type to filter, Enter picks the first match).
Future<void> pickTranslateLanguage(
  BuildContext context, {
  required bool source,
  bool autofocusSearch = false,
}) async {
  final cubit = context.read<TranslateCubit>();
  final picked = await showLanguagePicker(
    context,
    source: source,
    autofocusSearch: autofocusSearch,
  );
  if (picked == null) return;
  if (source) {
    cubit.setSource(picked);
  } else {
    cubit.setTarget(picked);
  }
}

/// Scripts used by essentially one language, so even a single word in them
/// is detected reliably (Hangul, kana, Thai, Greek, Georgian, Armenian,
/// Indic scripts other than Devanagari and Bengali, Sinhala, Myanmar, Khmer,
/// Lao, Tibetan, Ethiopic).
final _distinctiveScript = RegExp(
  '[Ͱ-Ͽ԰-֏਀-෿฀-໿ༀ-࿿'
  'က-႟Ⴀ-ჿᄀ-ᇿሀ-፿ក-៿'
  '぀-ヿ가-힯]',
);

/// Longest single word whose detected language is flagged as uncertain.
const uncertainDetectionMaxLength = 12;

/// Whether the detected source language may well be wrong: the source is
/// "Detect language" and the input is a single short word in a script that
/// several languages share (detectors often misjudge "Hallo", "Gift" or
/// "Bank").
bool detectionIsUncertain(TranslateState state) {
  if (!state.source.isAuto) return false;
  final detected = state.result?.detectedSource;
  if (detected == null || detected.isEmpty) return false;
  final text = state.input.trim();
  if (text.isEmpty || _distinctiveScript.hasMatch(text)) return false;
  return !text.contains(RegExp(r'\s')) &&
      text.characters.length <= uncertainDetectionMaxLength;
}

/// The language bar, like Kagi Translate's: one hairline-outlined pill
/// with the options button ([OptionsButton]) at the start, the source
/// button, the swap button and the target button, and the go button
/// ([TranslateGoButton]) at the end; thin dividers set the options and go
/// buttons off.
///
/// The source and target buttons share the space between the dividers:
/// half each while both names fit (the swap button then sits in the
/// middle, over the line between the panes of the wide layout); otherwise
/// the shorter name keeps its width and the longer one gets the rest.
///
/// A detection that may be wrong ([detectionLooksUncertain]: the engine
/// says so, or a single short word) reads "Detected: Dutch?" with a help
/// icon, like the chip under the translation.
///
/// Long-pressing the swap button opens the recent language pairs
/// ([showRecentPairsSheet]; also in the "More tools" menu for keyboard and
/// screen reader users).
///
/// Swapping ticks (a selection haptic) and turns the swap icon; a new
/// language name slides in along the bar's axis (the source's from the
/// target side, the target's from the source side) while the old one fades
/// out, like Material's shared-axis motion. No motion with reduced motion.
class LanguageBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final hairline = AppPalette.of(context).hairline;
    return DecoratedBox(
      key: const Key('translate_language_bar'),
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: hairline)),
      ),
      child: Padding(
        // Inside the outline.
        padding: const EdgeInsets.all(1),
        child: Row(
          children: [
            const OptionsButton(),
            _BarDivider(color: hairline),
            const Expanded(child: _LanguagePair()),
            _BarDivider(color: hairline),
            const TranslateGoButton(),
          ],
        ),
      ),
    );
  }
}

/// A short vertical hairline between the parts of the [LanguageBar].
class _BarDivider extends StatelessWidget {
  const new({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(width: 1, height: 24, child: ColoredBox(color: color)),
    );
  }
}

/// Source button, swap button and target button of the [LanguageBar].
class _LanguagePair extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.source != current.source ||
          previous.target != current.target ||
          previous.result?.detectedSource != current.result?.detectedSource ||
          detectionLooksUncertain(previous) !=
              detectionLooksUncertain(current) ||
          previous.sourceLanguages != current.sourceLanguages ||
          previous.canSwap != current.canSwap,
      builder: (context, state) {
        final detected = state.result?.detectedSource;
        final uncertain = detectionLooksUncertain(state);
        final String sourceLabel;
        final String sourceDescription;
        var sourceTooltip = '';
        if (!state.source.isAuto) {
          sourceLabel = sourceDescription = state.source.name;
        } else if (detected != null) {
          // The sparkle icon marks it as detected; keep the label short.
          sourceLabel = languageNameFor(detected, state.sourceLanguages);
          sourceDescription = uncertain
              ? l10n.translateDetectedLanguageUncertain(sourceLabel)
              : l10n.translateDetectedLanguage(sourceLabel);
          if (uncertain) {
            sourceTooltip =
                '$sourceDescription\n${l10n.translateDetectionUncertainHint}';
          }
        } else {
          sourceLabel = sourceDescription = l10n.translateDetectLanguage;
        }
        return _LanguagePairRow(
          children: [
            _LanguageButton(
              key: const Key('translate_source_button'),
              label: sourceLabel,
              slideFrom: AxisDirection.right,
              semanticLabel: l10n.translateSourceLanguage(sourceDescription),
              tooltip: sourceTooltip.isEmpty
                  ? sourceDescription
                  : sourceTooltip,
              icon: state.source.isCustom
                  ? Icons.auto_awesome
                  : !state.source.isAuto || detected == null
                  ? null
                  : uncertain
                  ? Icons.help_outline
                  : Icons.auto_awesome_outlined,
              onPressed: () => pickTranslateLanguage(context, source: true),
            ),
            _SwapButton(enabled: state.canSwap),
            _LanguageButton(
              key: const Key('translate_target_button'),
              label: state.target.name,
              slideFrom: AxisDirection.left,
              semanticLabel: l10n.translateTargetLanguage(state.target.name),
              tooltip: state.target.name,
              icon: state.target.isCustom ? Icons.auto_awesome : null,
              target: true,
              onPressed: () => pickTranslateLanguage(context, source: false),
            ),
          ],
        );
      },
    );
  }
}

/// Widths of two language buttons sharing [width], whose own (maximum
/// intrinsic) widths are [start] and [end]: half each while both fit in
/// half; otherwise the narrower one keeps its own width (when it fits in
/// half) and the wider one gets the rest; half each when neither fits in
/// half.
(double, double) languagePairSplit(double width, double start, double end) {
  final available = math.max(0, width).toDouble();
  final half = available / 2;
  if (start <= half && end <= half) return (half, half);
  if (start <= half) return (start, available - start);
  if (end <= half) return (available - end, end);
  return (half, half);
}

/// Lays out three children in a row, in reading order: two language
/// buttons with a swap button between them. The swap button keeps its own
/// width; the language buttons share the rest ([languagePairSplit]).
/// Children are centred vertically, and the row is as tall as the tallest
/// of them.
class _LanguagePairRow extends MultiChildRenderObjectWidget {
  const new({required super.children})
    : assert(children.length == 3, 'source, swap and target');

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLanguagePair(textDirection: Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLanguagePair renderObject,
  ) {
    renderObject.textDirection = Directionality.of(context);
  }
}

class _PairParentData extends ContainerBoxParentData<RenderBox>;

/// The render object of [_LanguagePairRow].
class _RenderLanguagePair extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PairParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PairParentData> {
  new({required this._textDirection});

  TextDirection _textDirection;

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PairParentData) {
      child.parentData = _PairParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => getChildrenAsList().fold(
    0,
    (sum, child) => sum + child.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) => getChildrenAsList().fold(
    0,
    (sum, child) => sum + child.getMaxIntrinsicWidth(height),
  );

  @override
  double computeMinIntrinsicHeight(double width) => getChildrenAsList().fold(
    0,
    (tallest, child) =>
        math.max(tallest, child.getMinIntrinsicHeight(double.infinity)),
  );

  @override
  double computeMaxIntrinsicHeight(double width) => getChildrenAsList().fold(
    0,
    (tallest, child) =>
        math.max(tallest, child.getMaxIntrinsicHeight(double.infinity)),
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  void performLayout() {
    final (:size, :widths) = _layout(
      constraints,
      ChildLayoutHelper.layoutChild,
    );
    this.size = size;
    final children = getChildrenAsList();
    final ordered = _textDirection == TextDirection.rtl
        ? children.reversed.toList()
        : children;
    final orderedWidths = _textDirection == TextDirection.rtl
        ? widths.reversed.toList()
        : widths;
    var x = 0.0;
    for (final (index, child) in ordered.indexed) {
      (child.parentData! as _PairParentData).offset = Offset(
        x,
        (size.height - child.size.height) / 2,
      );
      x += orderedWidths[index];
    }
  }

  /// Lays out (or dry lays out, with [layoutChild]) the children for
  /// [constraints]: the size of the row and the widths of the children.
  ({Size size, List<double> widths}) _layout(
    BoxConstraints constraints,
    ChildLayouter layoutChild,
  ) {
    final children = getChildrenAsList();
    assert(children.length == 3, '_LanguagePairRow needs three children');
    final [start, swap, end] = children;
    final swapWidth = swap.getMaxIntrinsicWidth(double.infinity);
    final startWidth = start.getMaxIntrinsicWidth(double.infinity);
    final endWidth = end.getMaxIntrinsicWidth(double.infinity);
    final (double, double) shared;
    if (constraints.hasBoundedWidth) {
      shared = languagePairSplit(
        constraints.maxWidth - swapWidth,
        startWidth,
        endWidth,
      );
    } else {
      shared = (startWidth, endWidth);
    }
    final widths = [shared.$1, swapWidth, shared.$2];
    var height = 0.0;
    for (final (index, child) in children.indexed) {
      final size = layoutChild(
        child,
        BoxConstraints.tightFor(width: widths[index])
            .copyWith(maxHeight: constraints.maxHeight),
      );
      height = math.max(height, size.height);
    }
    final size = constraints.constrain(
      Size(widths.fold(0, (sum, width) => sum + width), height),
    );
    return (size: size, widths: widths);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Swaps the languages (a selection haptic, the icon turns half a turn); a
/// long press opens the recent language pairs.
class _SwapButton extends StatefulWidget {
  const new({required this.enabled});

  final bool enabled;

  @override
  State<_SwapButton> createState() => _SwapButtonState();
}

class _SwapButtonState extends State<_SwapButton> {
  /// Turns of the icon: half a turn per swap.
  double _turns = 0;

  void _swap() {
    unawaited(HapticFeedback.selectionClick());
    setState(() => _turns += 0.5);
    context.read<TranslateCubit>().swap();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = widget.enabled;
    void showPairs() => unawaited(showRecentPairsSheet(context));
    // The tooltip shows on hover and focus only: a long press opens the
    // recent pairs instead.
    final button = MergeSemantics(
      child: Semantics(
        onLongPressHint: l10n.translateRecentPairsShow,
        child: Tooltip(
          message: l10n.translateSwapLanguages,
          triggerMode: TooltipTriggerMode.manual,
          child: IconButton(
            key: const Key('translate_swap_button'),
            style: IconButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
            icon: AnimatedRotation(
              turns: _turns,
              duration: _swapMotion(context),
              curve: Curves.easeInOutCubic,
              child: const Icon(Icons.swap_horiz),
            ),
            onPressed: enabled ? _swap : null,
            onLongPress: showPairs,
          ),
        ),
      ),
    );
    if (enabled) return button;
    // A disabled button ignores long presses; the pairs stay reachable.
    return GestureDetector(
      excludeFromSemantics: true,
      onLongPress: showPairs,
      child: button,
    );
  }
}

/// Duration of the swap motion; zero with reduced motion.
Duration _swapMotion(BuildContext context) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Duration.zero
    : const Duration(milliseconds: 250);

/// A language button of the [LanguageBar]: the name (the target's a
/// little bolder) and a chevron, on the bar without an outline of its own.
/// The button keeps its own semantics (tap action,
/// enabled state, focus); only its visible content is replaced by
/// [semanticLabel] for screen readers. A new [label] slides in from
/// [slideFrom] (mirrored in right-to-left layouts).
class _LanguageButton extends StatelessWidget {
  const new({
    required this.label,
    required this.semanticLabel,
    required this.tooltip,
    required this.onPressed,
    required this.slideFrom,
    this.icon,
    this.target = false,
    super.key,
  });

  /// The side a new label slides in from (in a left-to-right layout).
  final AxisDirection slideFrom;

  /// Whether this is the target language (bolder, like the translation's
  /// header).
  final bool target;

  final String label;
  final String semanticLabel;
  final String tooltip;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.only(start: 10, end: 4),
          shape: const StadiumBorder(),
          foregroundColor: scheme.onSurface,
          backgroundColor: Colors.transparent,
        ),
        onPressed: onPressed,
        child: Semantics(
          label: semanticLabel,
          // Hides only the visible Row text, not the button's actions.
          excludeSemantics: true,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: _SharedAxisSwitcher(
                  slideFrom: slideFrom,
                  child: Text(
                    label,
                    key: ValueKey(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: target ? FontWeight.w800 : FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 16, color: palette.secondaryText),
            ],
          ),
        ),
      ),
    );
  }
}

/// Switches [child] (told apart by its key) like Material's horizontal
/// shared-axis transition: the new one slides in from [slideFrom] while
/// fading in, the old one slides out the other way while fading out.
class _SharedAxisSwitcher extends StatelessWidget {
  const new({required this.slideFrom, required this.child});

  final AxisDirection slideFrom;
  final Widget child;

  /// How far a label travels, as a share of its width.
  static const _travel = 0.3;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final fromRight = (slideFrom == AxisDirection.right) != rtl;
    final current = child.key;
    return AnimatedSwitcher(
      duration: _swapMotion(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        // The incoming label enters from [slideFrom]; the outgoing one
        // (its animation runs backwards) leaves to the opposite side.
        final incoming = child.key == current;
        final sign = (fromRight ? 1.0 : -1.0) * (incoming ? 1 : -1);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(_travel * sign, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
