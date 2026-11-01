import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/dictionary/widgets/dictionary_attribution.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/view/dictionary_packs_page.dart'
    show openDictionaryPacks;
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Above an entry from an offline dictionary: "“went” is a form of “go”"
/// when the entry is the lemma of the looked-up form, and "Also a form of"
/// with the other lemmas, which look that word up ([onWordTap]). Nothing
/// otherwise.
class DictionaryOfflineNotice extends StatelessWidget {
  const new({required this.answer, required this.onWordTap, super.key});

  final OfflineDictionaryAnswer answer;
  final ValueChanged<String> onWordTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final form = answer.inflectedForm;
    final others = answer.otherLemmas;
    if (form == null && others.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('dictionary_offline_notice'),
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (form != null)
          Text(
            l10n.dictionaryInflectedForm(form, answer.entry.word),
            key: const Key('dictionary_inflected_form'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        if (others.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                l10n.dictionaryAlsoFormOf,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
              for (final word in others)
                TextButton(
                  key: ValueKey('dictionary_lemma:$word'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => onWordTap(word),
                  child: Text(word),
                ),
            ],
          ),
      ],
    );
  }
}

/// The end of an entry from an offline dictionary: where it comes from
/// and the language of its definitions ([glossLanguage]) in a
/// [DictionaryAttributionLink] and, with an AI engine, "More detail"
/// ([onMoreDetail]: the AI's fuller entry).
class DictionaryOfflineFooter extends StatelessWidget {
  const new({
    required this.attribution,
    this.onMoreDetail,
    this.glossLanguage,
    super.key,
  });

  final DictionaryAttribution attribution;

  /// The language code the definitions are written in, when known.
  final String? glossLanguage;
  final VoidCallback? onMoreDetail;

  @override
  Widget build(BuildContext context) {
    final onMoreDetail = this.onMoreDetail;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onMoreDetail != null)
          OutlinedButton.icon(
            key: const Key('dictionary_more_detail'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              shape: AppLook.of(context).control,
            ),
            onPressed: onMoreDetail,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: Text(context.l10n.translateShortMoreDetail),
          ),
        DictionaryAttributionLink(
          attribution: attribution,
          glossLanguage: glossLanguage,
        ),
      ],
    );
  }
}

/// The language the definitions of [answer]'s dictionary are written in
/// (its pack's `glossLanguage` in the catalogue of [packs]), or null when
/// the catalogue does not list it.
String? dictionaryGlossLanguage(
  DictionaryPacks? packs,
  OfflineDictionaryAnswer answer,
) => packs?.catalog.forLanguage(answer.language).firstOrNull?.glossLanguage;

/// "Similar words": [words] of the offline dictionaries as chips that look
/// that word up ([onWordTap]).
class DictionarySuggestions extends StatelessWidget {
  const new({required this.words, required this.onWordTap, super.key});

  final List<String> words;
  final ValueChanged<String> onWordTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      key: const Key('dictionary_suggestions'),
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.dictionarySuggestions,
            style: TranslateLayout.headingStyle(context),
          ),
        ),
        TranslatePills(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final word in words)
                ActionChip(
                  key: ValueKey('dictionary_suggestion:$word'),
                  label: Text(word),
                  tooltip: l10n.translateDictionaryLookUp(word),
                  onPressed: () => onWordTap(word),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Get dictionaries": opens the dictionaries screen for [packs].
class DictionaryGetPacksButton extends StatelessWidget {
  const new({required this.packs, super.key});

  final DictionaryPacks packs;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    key: const Key('dictionary_get_packs'),
    style: FilledButton.styleFrom(shape: AppLook.of(context).control),
    onPressed: () => unawaited(openDictionaryPacks(context, packs)),
    icon: const Icon(Icons.download_outlined),
    label: Text(context.l10n.dictionaryGetDictionaries),
  );
}
