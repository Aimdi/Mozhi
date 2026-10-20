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
    show languageNameFor;
import 'package:mozhi/web_translate/cubit/web_translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The web page's bar, like the translate screen's language bar: the
/// translation options ([OptionsButton]), the languages of the text
/// translator ([TranslateCubit]: picking or swapping them translates the
/// page again) and the go button, "Translate page" ([onGo]; disabled
/// while the page loads, a ring turns around it meanwhile).
///
/// With "Detect language" the source shows the language detected for the
/// page (with a sparkle), not the one of the translate screen's text.
/// Long-pressing the swap button opens the recent language pairs.
class WebLanguageBar extends StatelessWidget {
  const new({required this.onGo, super.key});

  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (source, target, canSwap, languages) = context
        .select<TranslateCubit, (Language, Language, bool, List<Language>)>(
          (cubit) => (
            cubit.state.source,
            cubit.state.target,
            cubit.state.canSwap,
            cubit.state.sourceLanguages,
          ),
        );
    final (detectedCode, loading) = context
        .select<WebTranslateCubit, (String?, bool)>(
          (cubit) => (
            cubit.state.detectedSource,
            cubit.state.status == WebTranslateStatus.loading,
          ),
        );
    final detected = source.isAuto && detectedCode != null
        ? languageNameFor(detectedCode, languages)
        : null;
    final sourceLabel = source.isAuto
        ? detected ?? l10n.translateDetectLanguage
        : source.name;
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
        label: target.name,
        semanticLabel: l10n.translateTargetLanguage(target.name),
        icon: target.isCustom ? Icons.auto_awesome : null,
        onPressed: () =>
            unawaited(pickTranslateLanguage(context, source: false)),
      ),
      middle: LanguageSwapButton(
        key: const Key('web_translate_swap_button'),
        tooltip: l10n.translateSwapLanguages,
        onPressed: canSwap ? context.read<TranslateCubit>().swap : null,
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
