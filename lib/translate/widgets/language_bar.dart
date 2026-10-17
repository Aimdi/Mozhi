import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/detection_chips.dart';
import 'package:mozhi/translate/widgets/language_picker_sheet.dart';
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

/// Source button, swap button and target button.
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
        return Row(
          children: [
            Expanded(
              child: _LanguageButton(
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
            ),
            SizedBox(
              width: TranslateLayout.paneGap,
              child: _SwapButton(enabled: state.canSwap),
            ),
            Expanded(
              child: _LanguageButton(
                key: const Key('translate_target_button'),
                label: state.target.name,
                slideFrom: AxisDirection.left,
                semanticLabel: l10n.translateTargetLanguage(state.target.name),
                tooltip: state.target.name,
                icon: state.target.isCustom ? Icons.auto_awesome : null,
                target: true,
                onPressed: () => pickTranslateLanguage(context, source: false),
              ),
            ),
          ],
        );
      },
    );
  }
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
          child: IconButton.outlined(
            key: const Key('translate_swap_button'),
            style: IconButton.styleFrom(
              side: BorderSide(color: AppPalette.of(context).hairline),
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

/// An X-style pill language button with a hairline border (the target's
/// a little bolder). The button keeps its own semantics (tap action,
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
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.only(start: 16, end: 10),
          shape: const StadiumBorder(),
          side: BorderSide(color: palette.hairline),
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
              Icon(Icons.expand_more, size: 20, color: palette.secondaryText),
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
