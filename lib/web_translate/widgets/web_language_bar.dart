import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/language_pair_bar.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_bar.dart'
    show pickTranslateLanguage;
import 'package:mozhi/translate/widgets/options_sheet.dart' show OptionsButton;
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart'
    show languageNameFor, localizedLanguageNameFor;
import 'package:mozhi/web_translate/cubit/web_translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The languages the web page's swap button applies for [state] (the text
/// translator's): its target becomes the source, and its source the target
/// — with "Detect language", the language detected for the page
/// ([detectedSource], `WebTranslateState.detectedSource`), not the one the
/// translate screen detected for its own text. Both as the engine lists
/// them. Null when the languages cannot be swapped: a custom target, no
/// language detected for the page yet, or a language the engine does not
/// offer on its new side.
LanguagePair? webSwapPair(TranslateState state, String? detectedSource) {
  if (!state.canSwap) return null;
  final Language from;
  if (state.source.isAuto) {
    final code = detectedSource?.trim() ?? '';
    if (code.isEmpty) return null;
    from = Language(
      code: code,
      name: languageNameFor(code, state.sourceLanguages),
    );
  } else {
    from = state.source;
  }
  final target = state.usableTarget(from);
  final source = LanguageMatcher.match(state.target, state.sourceLanguages);
  if (target == null || source == null) return null;
  return LanguagePair(source: source, target: target);
}

/// The web page's bar, like the translate screen's language bar: the
/// translation options ([OptionsButton]), the languages of the text
/// translator ([TranslateCubit]: picking or swapping them translates the
/// page again) and the go button, "Translate page" ([onGo]; disabled
/// while the page loads, a ring turns around it meanwhile).
///
/// With "Detect language" the source shows the language detected for the
/// page (with a sparkle), not the one of the translate screen's text, and
/// the swap button swaps with it ([webSwapPair]; disabled until it is
/// detected). Swapping only changes the languages, like picking them: the
/// translate screen's text stays as it is. Long-pressing the swap button
/// opens the recent language pairs.
class WebLanguageBar extends StatelessWidget {
  const new({required this.onGo, super.key});

  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (detectedCode, loading) = context
        .select<WebTranslateCubit, (String?, bool)>(
          (cubit) => (
            cubit.state.detectedSource,
            cubit.state.status == WebTranslateStatus.loading,
          ),
        );
    final (source, target, swapped, languages) = context
        .select<
          TranslateCubit,
          (Language, Language, LanguagePair?, List<Language>)
        >(
          (cubit) => (
            cubit.state.source,
            cubit.state.target,
            webSwapPair(cubit.state, detectedCode),
            cubit.state.sourceLanguages,
          ),
        );
    final detected = source.isAuto && detectedCode != null
        ? localizedLanguageNameFor(context, detectedCode, languages)
        : null;
    final sourceLabel = source.isAuto
        ? detected ?? l10n.translateDetectLanguage
        : context.languageName(source);
    final sourceDescription = detected == null
        ? sourceLabel
        : l10n.translateDetectedLanguage(detected);
    return LanguagePairBar(
      key: const Key('web_translate_language_bar'),
      leading: const [OptionsButton()],
      source: LanguagePairSide(
        key: const Key('web_translate_source_button'),
        label: sourceLabel,
        semanticLabel: l10n.translateSourceLanguage(sourceDescription),
        tooltip: sourceDescription,
        icon: source.isCustom
            ? Icons.auto_awesome
            : detected != null
            ? Icons.auto_awesome_outlined
            : null,
        onPressed: () =>
            unawaited(pickTranslateLanguage(context, source: true)),
      ),
      target: LanguagePairSide(
        key: const Key('web_translate_target_button'),
        label: context.languageName(target),
        semanticLabel: l10n.translateTargetLanguage(
          context.languageName(target),
        ),
        icon: target.isCustom ? Icons.auto_awesome : null,
        onPressed: () =>
            unawaited(pickTranslateLanguage(context, source: false)),
      ),
      middle: LanguageSwapButton(
        key: const Key('web_translate_swap_button'),
        tooltip: l10n.translateSwapLanguages,
        // Only the languages: not `TranslateCubit.swap`, which uses the
        // translate screen's detection and moves its translation into its
        // input.
        onPressed: swapped == null
            ? null
            : () => context.read<TranslateCubit>().applyLanguagePair(swapped),
        onLongPress: () => unawaited(showRecentPairsSheet(context)),
        longPressHint: l10n.translateRecentPairsShow,
      ),
      trailing: [
        ComposerGoButton(
          key: const Key('web_translate_go_button'),
          label: l10n.webTranslateGo,
          busy: loading,
          onPressed: loading ? null : onGo,
        ),
      ],
    );
  }
}
