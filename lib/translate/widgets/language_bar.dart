import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
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
                semanticLabel: l10n.translateTargetLanguage(state.target.name),
                tooltip: state.target.name,
                icon: state.target.isCustom ? Icons.auto_awesome : null,
                onPressed: () => pickTranslateLanguage(context, source: false),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Swaps the languages; a long press opens the recent language pairs.
class _SwapButton extends StatelessWidget {
  const new({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
            icon: const Icon(Icons.swap_horiz),
            onPressed: enabled ? context.read<TranslateCubit>().swap : null,
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

/// A tonal language button. The button keeps its own semantics (tap action,
/// enabled state, focus); only its visible content is replaced by
/// [semanticLabel] for screen readers.
class _LanguageButton extends StatelessWidget {
  const new({
    required this.label,
    required this.semanticLabel,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final String tooltip;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: FilledButton.tonal(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
          foregroundColor: theme.colorScheme.onSurface,
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
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const Icon(Icons.expand_more, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
