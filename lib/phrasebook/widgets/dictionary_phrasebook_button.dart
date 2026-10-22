import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/phrasebook/widgets/add_to_phrasebook.dart';
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart';

/// The dictionary entry in [state] as a phrase: its word with its first
/// translation into the target language (else the entry's one-line
/// summary, as the history keeps it), in the entry's languages; null
/// while there is no entry.
PhraseDraft? dictionaryPhraseDraft(DictionaryState state) {
  final entry = state.entry;
  if (state.status != DictionaryStatus.success ||
      entry == null ||
      state.isEmptyEntry) {
    return null;
  }
  String? translation;
  for (final sense in entry.senses) {
    for (final value in sense.translations) {
      if (value.trim().isNotEmpty) {
        translation = value.trim();
        break;
      }
    }
    if (translation != null) break;
  }
  final word = entry.word.trim().isNotEmpty ? entry.word : state.lookedUp;
  final draft = PhraseDraft(
    text: word.trim(),
    translation: translation ?? DictionaryCubit.historySummary(entry),
    sourceCode: phraseLanguageOf(state.source, detected: state.entryLanguage),
    targetCode: phraseLanguageOf(state.target),
    origin: PhraseOrigin.dictionary,
  );
  return draft.isEmpty ? null : draft;
}

/// "Add to phrasebook…" beside the dictionary entry's heart: the word and
/// its translation into a collection ([showAddToPhrasebook]). Shown
/// (disabled) while the entry loads, like the heart; nothing for an error
/// or without a [PhrasebookRepository] above.
class DictionaryPhrasebookButton extends StatelessWidget {
  const new({super.key});

  /// Width and height of the round button (the Listen button's).
  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    if (maybePhrasebookRepository(context) == null) {
      return const SizedBox.shrink();
    }
    final status = context.select<DictionaryCubit, DictionaryStatus>(
      (cubit) => cubit.state.status,
    );
    final draft = context.select<DictionaryCubit, PhraseDraft?>(
      (cubit) => dictionaryPhraseDraft(cubit.state),
    );
    if (draft == null && status != DictionaryStatus.loading) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    return IconButton.outlined(
      key: const Key('dictionary_phrasebook'),
      tooltip: context.l10n.phrasebookAdd,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(size),
        side: BorderSide(color: colors.outline),
        foregroundColor: colors.onSurface,
      ),
      icon: const Icon(Icons.bookmark_add_outlined),
      onPressed: draft == null
          ? null
          : () {
              Haptics.light(context);
              unawaited(showAddToPhrasebook(context, draft));
            },
    );
  }
}
