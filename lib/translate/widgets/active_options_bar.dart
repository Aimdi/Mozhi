import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/options_sheet.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// One non-default translation option: its chip `label` (and `tooltip`)
/// and the options with just that option reset (`cleared`).
typedef ActiveTranslationOption = ({
  String label,
  String? tooltip,
  TranslationOptions cleared,
});

/// Longest context excerpt shown on its chip.
const _contextPreviewLength = 24;

/// The user-chosen options that differ from the defaults, in the order of
/// the options sheet.
List<ActiveTranslationOption> activeTranslationOptions(
  AppLocalizations l10n,
  TranslationOptions options,
) {
  final context = options.context.trim();
  return [
    if (options.style != TranslationStyle.natural)
      (
        label: l10n.translateStyleLiteral,
        tooltip: null,
        cleared: options.copyWith(style: TranslationStyle.natural),
      ),
    if (options.formality != Formality.automatic)
      (
        label: translateFormalityLabel(l10n, options.formality),
        tooltip: null,
        cleared: options.copyWith(formality: Formality.automatic),
      ),
    if (options.readingLevel != ReadingLevel.standard)
      (
        label: l10n.translateActiveOptionReadingLevel(
          options.readingLevel.name.toUpperCase(),
        ),
        tooltip: translateReadingLevelLabel(l10n, options.readingLevel),
        cleared: options.copyWith(readingLevel: ReadingLevel.standard),
      ),
    if (options.speakerGender != Gender.unknown)
      (
        label: l10n.translateActiveOptionSpeaker(
          translateGenderLabel(l10n, options.speakerGender),
        ),
        tooltip: null,
        cleared: options.copyWith(speakerGender: Gender.unknown),
      ),
    if (options.addresseeGender != Gender.unknown)
      (
        label: l10n.translateActiveOptionAddressee(
          translateGenderLabel(l10n, options.addresseeGender),
        ),
        tooltip: null,
        cleared: options.copyWith(addresseeGender: Gender.unknown),
      ),
    if (context.isNotEmpty)
      (
        label: l10n.translateActiveOptionContext(
          context.characters.length <= _contextPreviewLength
              ? context
              : '${context.characters.take(_contextPreviewLength)}…',
        ),
        tooltip: context,
        cleared: options.copyWith(context: ''),
      ),
    if (!options.preserveFormatting)
      (
        label: l10n.translateActiveOptionNoFormatting,
        tooltip: null,
        cleared: options.copyWith(preserveFormatting: true),
      ),
    if (options.glossary.isNotEmpty)
      (
        label: l10n.translateActiveOptionGlossary(options.glossary.length),
        tooltip: options.glossary.entries
            .map((e) => l10n.translateGlossaryEntry(e.key, e.value))
            .join('\n'),
        cleared: options.copyWith(glossary: const {}),
      ),
  ];
}

/// Chips under the language bar for every translation option that differs
/// from the defaults (AI engines only).
///
/// Options persist across sessions, so a stale context ("a text to my
/// landlord") or formality would otherwise silently skew later
/// translations. Tapping a chip opens the options sheet, its delete button
/// clears that option, and "Reset options" clears them all.
class ActiveOptionsBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.engine != current.engine ||
          !identical(previous.options, current.options),
      builder: (context, state) {
        final options = state.options;
        if (!(state.engine?.supportsOptions ?? false) ||
            optionsAreDefault(options)) {
          return const SizedBox.shrink();
        }
        final cubit = context.read<TranslateCubit>();
        final active = activeTranslationOptions(l10n, options);
        return Padding(
          padding: const EdgeInsets.only(top: TranslateLayout.gap),
          child: Semantics(
            key: const Key('translate_active_options'),
            container: true,
            explicitChildNodes: true,
            label: l10n.translateActiveOptionsLabel,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final option in active)
                  InputChip(
                    key: ValueKey('translate_active_option:${option.label}'),
                    avatar: const Icon(Icons.tune),
                    label: Text(option.label),
                    tooltip: option.tooltip,
                    onPressed: () => unawaited(showOptionsSheet(context)),
                    onDeleted: () => cubit.setOptions(option.cleared),
                    deleteButtonTooltipMessage: l10n
                        .translateActiveOptionRemove(option.label),
                  ),
                TextButton.icon(
                  key: const Key('translate_active_options_reset'),
                  onPressed: () => cubit.setOptions(
                    TranslationOptions(instructions: options.instructions),
                  ),
                  icon: const Icon(Icons.restart_alt),
                  label: Text(l10n.translateActiveOptionsReset),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
