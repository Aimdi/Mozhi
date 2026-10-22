import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/dictionary_language_picker.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the searchable list of the word's languages ([source]) or of the
/// translations' languages and applies the choice to the
/// [DictionaryCubit] of [context].
Future<void> pickDictionaryLanguage(
  BuildContext context, {
  required bool source,
}) async {
  final l10n = context.l10n;
  final cubit = context.read<DictionaryCubit>();
  final state = cubit.state;
  final picked = await showDictionaryLanguagePicker(
    context,
    title: source
        ? l10n.dictionaryPickSourceTitle
        : l10n.dictionaryPickTargetTitle,
    languages: source
        ? DictionaryLanguageBar.sourceLanguages
        : DictionaryLanguageBar.targetLanguages,
    selected: source ? state.source : state.target,
  );
  if (picked == null || cubit.isClosed) return;
  if (source) {
    cubit.setSource(picked);
  } else {
    cubit.setTarget(picked);
  }
}

/// The word's language, a swap button and the translations' language, as
/// outlined pills with the language avatars: the languages section of the
/// options sheet (`DictionaryOptionsSheet`). The composer's bar shows them
/// compactly (`DictionaryLanguagePair`).
class DictionaryLanguageBar extends StatelessWidget {
  const new({super.key});

  /// Languages the word can be in ([Language.auto] first).
  static List<Language> get sourceLanguages => [
    Language.auto,
    ...LanguageCatalog.all,
  ];

  /// Languages translations can be in.
  static List<Language> get targetLanguages => LanguageCatalog.all;

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
            code: source.code,
            label: sourceName,
            semanticsLabel: source.isAuto
                ? l10n.dictionarySourceLanguageAuto
                : l10n.dictionarySourceLanguage(sourceName),
            onPressed: () =>
                unawaited(pickDictionaryLanguage(context, source: true)),
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
            code: target.code,
            label: targetName,
            semanticsLabel: l10n.dictionaryTargetLanguage(targetName),
            onPressed: () =>
                unawaited(pickDictionaryLanguage(context, source: false)),
          ),
        ),
      ],
    );
  }
}

/// An outlined pill with the language's avatar.
class _LanguageButton extends StatelessWidget {
  const new({
    required this.code,
    required this.label,
    required this.semanticsLabel,
    required this.onPressed,
    super.key,
  });

  final String code;
  final String label;
  final String semanticsLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: colors.onSurface,
        side: BorderSide(color: colors.outline),
        shape: const StadiumBorder(),
        padding: const EdgeInsetsDirectional.fromSTEB(6, 6, 8, 6),
        textStyle: Theme.of(context).textTheme.labelLarge
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      // The button reads "Language of the word: Spanish", not just
      // "Spanish".
      child: Semantics(
        label: semanticsLabel,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            LanguageAvatar(code: code, size: 28),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            Icon(Icons.expand_more, size: 20, color: palette.secondaryText),
          ],
        ),
      ),
    );
  }
}
