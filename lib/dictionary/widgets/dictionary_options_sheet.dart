import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/widgets/dictionary_language_bar.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart'
    show DictionaryVerbosityChips;
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the dictionary's options ([DictionaryOptionsSheet]) for the
/// [DictionaryCubit] of [context].
Future<void> showDictionaryOptions(BuildContext context) {
  final cubit = context.read<DictionaryCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        BlocProvider.value(value: cubit, child: const DictionaryOptionsSheet()),
  );
}

/// The options button of the dictionary ("tune"): opens
/// [showDictionaryOptions].
class DictionaryOptionsButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return ComposerOptionsButton(
      tooltip: context.l10n.dictionaryOptionsTooltip,
      onPressed: () => unawaited(showDictionaryOptions(context)),
    );
  }
}

/// The dictionary's options: the detail level (Concise, Standard,
/// Detailed), the languages with the swap button ([DictionaryLanguageBar])
/// and the AI engine that writes the entries. A change looks the shown
/// word up again (see [DictionaryCubit]).
class DictionaryOptionsSheet extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final (engine, verbosity) = context
        .select<DictionaryCubit, (TranslationEngine?, DictionaryVerbosity)>(
          (cubit) => (cubit.state.engine, cubit.state.verbosity),
        );
    final heading = TranslateLayout.headingStyle(context);
    return SingleChildScrollView(
      key: const Key('dictionary_options_sheet'),
      // The sheet's safe area leaves out the bottom: keep the last row
      // above the navigation bar (edge to edge).
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.dictionaryOptionsTitle,
              style: TranslateLayout.sectionHeadingStyle(context),
            ),
          ),
          const SizedBox(height: 20),
          ExcludeSemantics(
            // The chips' group already says it.
            child: Text(l10n.translateDictionaryDetailLevel, style: heading),
          ),
          const SizedBox(height: 8),
          DictionaryVerbosityChips(
            key: const Key('dictionary_verbosity'),
            value: verbosity,
            onChanged: (level) =>
                unawaited(context.read<DictionaryCubit>().setVerbosity(level)),
          ),
          const SizedBox(height: 24),
          Semantics(
            header: true,
            child: Text(l10n.dictionaryLanguagesTitle, style: heading),
          ),
          const SizedBox(height: 8),
          const DictionaryLanguageBar(),
          if (engine != null) ...[
            const SizedBox(height: 20),
            Text(
              l10n.dictionaryEngine(engine.name),
              key: const Key('dictionary_engine'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppPalette.of(context).secondaryText,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
