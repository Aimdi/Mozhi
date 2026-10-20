import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_bar.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Whether the detected source language of [state] may be wrong: the
/// engine says so ([TranslateState.detectionUncertain]) or the input is a
/// single short word ([detectionIsUncertain]).
bool detectionLooksUncertain(TranslateState state) =>
    state.detectionUncertain || detectionIsUncertain(state);

/// "Detected: Dutch" under the translation (auto source only; nothing
/// otherwise). Tapping it opens the source language picker to correct the
/// detection.
///
/// An uncertain detection ([detectionLooksUncertain]) reads "Detected:
/// Dutch?" and is followed by a chip for each other language the input
/// may be in ([TranslateState.detectedAlternativeLanguages], e.g. German,
/// Afrikaans); choosing one translates from it
/// ([TranslateCubit.useDetectedAlternative]).
class DetectedLanguageChips extends StatelessWidget {
  const new({required this.state, super.key});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final detected = state.result?.detectedSource;
    if (detected == null || detected.isEmpty || !state.source.isAuto) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final uncertain = detectionLooksUncertain(state);
    final alternatives = uncertain
        ? state.detectedAlternativeLanguages
        : const <Language>[];
    final chip = _DetectedChip(
      language: languageNameFor(detected, state.sourceLanguages),
      uncertain: uncertain,
    );
    if (alternatives.isEmpty) return chip;
    final cubit = context.read<TranslateCubit>();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        chip,
        Semantics(
          key: const Key('translate_detected_alternatives'),
          container: true,
          explicitChildNodes: true,
          label: l10n.translateDetectedAlternativesLabel,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final language in alternatives)
                ActionChip(
                  key: ValueKey(
                    'translate_detected_alternative:${language.code}',
                  ),
                  // The name is in the UI language (no language locale, so
                  // screen readers keep the UI voice).
                  label: Text(language.name),
                  tooltip: l10n.translateDetectedAlternativeHint(language.name),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => cubit.useDetectedAlternative(language.code),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Detected: X" (or "Detected: X?" when uncertain); opens the source
/// language picker.
class _DetectedChip extends StatelessWidget {
  const new({required this.language, required this.uncertain});

  final String language;
  final bool uncertain;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final label = uncertain
        ? l10n.translateDetectedLanguageUncertain(language)
        : l10n.translateDetectedLanguage(language);
    // The theme's outlined pill (no fill), like the app's other chips.
    return ActionChip(
      key: const Key('translate_detected_chip'),
      avatar: Icon(
        uncertain ? Icons.help_outline : Icons.auto_awesome_outlined,
        color: scheme.primary,
      ),
      label: Text(label),
      tooltip: uncertain
          ? l10n.translateDetectionUncertainHint
          : l10n.translateChangeSourceLanguage,
      labelStyle: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: scheme.onSurface),
      visualDensity: VisualDensity.compact,
      onPressed: () => unawaited(pickTranslateLanguage(context, source: true)),
    );
  }
}
