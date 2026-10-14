import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart';

/// The output in the Latin script: the loaded
/// [TranslateState.romanization], else the result's own transliteration
/// (Mozhi); null when there is none.
String? romanizationOf(TranslateState state) {
  final romanization = state.romanization?.trim() ?? '';
  if (romanization.isNotEmpty) return romanization;
  final transliteration = state.result?.targetTransliteration.trim() ?? '';
  return transliteration.isEmpty ? null : transliteration;
}

/// Whether a romanization can be shown for [state] (one is there, or
/// [TranslateState.canRomanize]).
bool romanizationAvailable(TranslateState state) =>
    romanizationOf(state) != null || state.canRomanize;

/// [Locale] of a romanization of text in [language]: the language in the
/// Latin script (`ja-Latn`), so screen readers keep the language's voice;
/// null for auto and custom languages.
Locale? romanizationLocale(Language language) {
  final locale = localeForLanguage(language);
  if (locale == null) return null;
  return Locale.fromSubtags(
    languageCode: locale.languageCode,
    scriptCode: 'Latn',
    countryCode: locale.countryCode,
  );
}

/// The romanization under a non-Latin translation (muted, selectable,
/// left to right in the target language's Latin-script locale), or its
/// loading and error states.
///
/// Shows nothing when there is nothing to show; the "Show romanization"
/// toggle lives with the output's actions (see [RomanizationButton]).
class RomanizationLine extends StatelessWidget {
  const new({required this.state, this.announce = false, super.key});

  final TranslateState state;

  /// Tell screen-reader users when the romanization arrives (it was asked
  /// for, not shown automatically).
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final text = romanizationOf(state);
    final Widget? child;
    if (text != null) {
      child = Semantics(
        container: true,
        label: l10n.translateRomanizationLabel,
        child: SizedBox(
          width: double.infinity,
          child: SelectableText.rich(
            TextSpan(text: text, locale: romanizationLocale(state.target)),
            key: const Key('translate_output_transliteration'),
            // Latin script: always left to right, also in RTL layouts.
            textDirection: TextDirection.ltr,
            style: theme.textTheme.bodyLarge?.copyWith(color: muted),
          ),
        ),
      );
    } else {
      switch (state.romanizationStatus) {
        case ExtraStatus.loading:
          child = Semantics(
            container: true,
            child: Row(
              key: const Key('translate_romanization_progress'),
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: l10n.translateRomanizationLoading,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: ExcludeSemantics(
                    child: Text(
                      l10n.translateRomanizationLoading,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  ),
                ),
              ],
            ),
          );
        case ExtraStatus.failure:
          child = TranslateErrorView(
            key: const Key('translate_romanization_error'),
            error: state.romanizationError,
            dense: true,
            onRetry: () =>
                unawaited(context.read<TranslateCubit>().loadRomanization()),
          );
        case ExtraStatus.idle:
        case ExtraStatus.ready:
          child = null;
      }
    }
    // Always built (also while empty), so that a romanization arriving
    // later is announced.
    return StatusAnnouncer(
      message: announce && text != null
          ? l10n.translateRomanizationReady
          : null,
      child: child == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
              child: child,
            ),
    );
  }
}

/// Toggles the romanization of the output ("Show romanization" / "Hide
/// romanization"); selected while it is shown.
class RomanizationButton extends StatelessWidget {
  const new({required this.shown, required this.onPressed, super.key});

  /// Whether the romanization (or its progress or error) is shown.
  final bool shown;

  /// Null disables the button.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return IconButton(
      key: const Key('translate_romanize_button'),
      tooltip: shown
          ? l10n.translateRomanizationHide
          : l10n.translateRomanizationShow,
      isSelected: shown,
      icon: const Icon(Icons.abc_outlined),
      selectedIcon: const Icon(Icons.abc),
      onPressed: onPressed,
    );
  }
}
