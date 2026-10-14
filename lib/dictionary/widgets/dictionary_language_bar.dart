import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/dictionary_language_picker.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// The word's language, a swap button and the translations' language.
class DictionaryLanguageBar extends StatelessWidget {
  const new({super.key});

  /// Languages the word can be in ([Language.auto] first).
  static List<Language> get sourceLanguages => [
    Language.auto,
    ...LanguageCatalog.all,
  ];

  /// Languages translations can be in.
  static List<Language> get targetLanguages => LanguageCatalog.all;

  Future<void> _pick(BuildContext context, {required bool source}) async {
    final l10n = context.l10n;
    final cubit = context.read<DictionaryCubit>();
    final state = cubit.state;
    final picked = await showDictionaryLanguagePicker(
      context,
      title: source
          ? l10n.dictionaryPickSourceTitle
          : l10n.dictionaryPickTargetTitle,
      languages: source ? sourceLanguages : targetLanguages,
      selected: source ? state.source : state.target,
    );
    if (picked == null || cubit.isClosed) return;
    if (source) {
      cubit.setSource(picked);
    } else {
      cubit.setTarget(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (source, target, canSwap) = context
        .select<DictionaryCubit, (Language, Language, bool)>(
          (cubit) =>
              (cubit.state.source, cubit.state.target, cubit.state.canSwap),
        );
    final sourceName = dictionaryLanguageName(l10n, source);
    final targetName = dictionaryLanguageName(l10n, target);
    return Row(
      children: [
        Expanded(
          child: _LanguageButton(
            key: const Key('dictionary_source_language'),
            label: sourceName,
            semanticsLabel: source.isAuto
                ? l10n.dictionarySourceLanguageAuto
                : l10n.dictionarySourceLanguage(sourceName),
            onPressed: () => unawaited(_pick(context, source: true)),
          ),
        ),
        IconButton(
          key: const Key('dictionary_swap'),
          tooltip: l10n.dictionarySwapLanguages,
          icon: const Icon(Icons.swap_horiz),
          onPressed: canSwap ? context.read<DictionaryCubit>().swap : null,
        ),
        Expanded(
          child: _LanguageButton(
            key: const Key('dictionary_target_language'),
            label: targetName,
            semanticsLabel: l10n.dictionaryTargetLanguage(targetName),
            onPressed: () => unawaited(_pick(context, source: false)),
          ),
        ),
      ],
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const new({
    required this.label,
    required this.semanticsLabel,
    required this.onPressed,
    super.key,
  });

  final String label;
  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: onPressed,
      // The button reads "Language of the word: Spanish", not just
      // "Spanish".
      child: Semantics(
        label: semanticsLabel,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
