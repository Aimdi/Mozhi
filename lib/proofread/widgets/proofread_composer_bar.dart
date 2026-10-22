import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/widgets/proofread_button.dart';
import 'package:mozhi/proofread/widgets/proofread_controls.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// The bar of the proofreading composer, in the order of every composer
/// (Translate, Dictionary): the options button ([ProofreadOptionsButton]),
/// the language ([ProofreadLanguageButton]) and the go button
/// ([ProofreadButton]) at the trailing end.
class ProofreadComposerBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return const ComposerBar(
      key: Key('proofread_bar'),
      children: [
        ProofreadOptionsButton(key: Key('proofread_options_button')),
        Expanded(
          child: ProofreadLanguageButton(key: Key('proofread_language_button')),
        ),
        ProofreadButton(key: Key('proofread_button')),
      ],
    );
  }
}

/// Whether any option of [state] shown in the options sheet differs from
/// its default (the language has its own button).
bool proofreadOptionsModified(ProofreadState state) =>
    state.correctionLevel != CorrectionLevel.standard ||
    state.writingStyle != WritingStyle.general ||
    state.formality != Formality.automatic ||
    state.readingLevel != ReadingLevel.standard ||
    state.context.trim().isNotEmpty;

/// Opens the proofreading options ([ProofreadControls]) for the
/// [ProofreadCubit] of [context].
Future<void> showProofreadOptions(BuildContext context) {
  final cubit = context.read<ProofreadCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        BlocProvider.value(value: cubit, child: const ProofreadOptionsSheet()),
  );
}

/// The options button of the proofreading composer ("tune", with a dot
/// while an option differs from its default): opens
/// [showProofreadOptions].
class ProofreadOptionsButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final modified = context.select<ProofreadCubit, bool>(
      (cubit) => proofreadOptionsModified(cubit.state),
    );
    return ComposerOptionsButton(
      tooltip: modified
          ? l10n.proofreadOptionsModifiedTooltip
          : l10n.proofreadOptionsTooltip,
      modified: modified,
      onPressed: () => unawaited(showProofreadOptions(context)),
    );
  }
}

/// The proofreading options in a bottom sheet: correction level, style,
/// formality, reading level, region, model and context. It stays above the
/// keyboard (the bottom sheet does not avoid it), scrolling when it does
/// not fit.
class ProofreadOptionsSheet extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        key: const Key('proofread_options_sheet'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: [
            Semantics(
              header: true,
              child: Text(
                context.l10n.proofreadOptionsTitle,
                style: TranslateLayout.sectionHeadingStyle(context),
              ),
            ),
            const ProofreadControls(),
          ],
        ),
      ),
    );
  }
}

/// The name of the language the [ProofreadLanguageButton] shows for
/// [state]: the chosen region, else the detected language, else "Detect
/// language"; and whether it was detected.
(String, bool) proofreadLanguageLabel(
  AppLocalizations l10n,
  ProofreadState state,
) {
  final variety = state.variety;
  if (variety != null) return (l10n.proofreadVariety(variety), false);
  final detected = state.result?.detectedLanguage?.trim() ?? '';
  final language = detected.isEmpty ? null : LanguageCatalog.byCode(detected);
  if (language != null) return (language.name, true);
  return (l10n.proofreadLanguageAuto, false);
}

/// The language of the proofreading composer, in the look of the other
/// composers' language buttons (the name and a small chevron): "Detect
/// language" (the author's language and spelling are kept; once checked,
/// the detected language with a sparkle) or the chosen regional variety
/// ("English (UK)"). It opens the list ([showProofreadLanguages]).
class ProofreadLanguageButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, detected, auto) = context
        .select<ProofreadCubit, (String, bool, bool)>((cubit) {
          final (label, detected) = proofreadLanguageLabel(l10n, cubit.state);
          final auto = cubit.state.variety == null && !detected;
          return (label, detected, auto);
        });
    final description = detected
        ? l10n.proofreadLanguageDetected(label)
        : label;
    return Tooltip(
      message: description,
      excludeFromSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.only(start: 10, end: 6),
          shape: const StadiumBorder(),
          foregroundColor: scheme.onSurface,
        ),
        onPressed: () => unawaited(showProofreadLanguages(context)),
        child: Semantics(
          // Not "Language: Detect language", as if that were one.
          label: auto
              ? l10n.proofreadLanguageAutoSemantics
              : l10n.proofreadLanguageButton(description),
          excludeSemantics: true,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (detected) ...[
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more,
                size: 16,
                color: AppPalette.of(context).secondaryText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the list of languages to proofread in: "Detect language" (keep
/// the author's spelling and vocabulary) and the regional varieties; the
/// choice is applied to the [ProofreadCubit] of [context].
Future<void> showProofreadLanguages(BuildContext context) async {
  final cubit = context.read<ProofreadCubit>();
  final current = cubit.state.variety;
  final picked = await showModalBottomSheet<_LanguageChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _LanguageSheet(selected: current),
  );
  if (picked == null || cubit.isClosed) return;
  cubit.setVariety(picked.variety);
}

/// A picked entry of the language list (null: detect).
class _LanguageChoice {
  const new(this.variety);

  final ProofreadVariety? variety;
}

class _LanguageSheet extends StatelessWidget {
  const new({required this.selected});

  final ProofreadVariety? selected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    Widget tile(ProofreadVariety? variety) {
      final isSelected = variety == selected;
      return ListTile(
        key: ValueKey('proofread_language_${variety?.code ?? 'auto'}'),
        contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 16),
        selected: isSelected,
        leading: Icon(
          variety == null ? Icons.auto_awesome_outlined : Icons.public,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          variety == null
              ? l10n.proofreadLanguageAuto
              : l10n.proofreadVariety(variety),
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        subtitle: variety == null
            ? Text(
                l10n.proofreadVarietyKeepDescription,
                style: TextStyle(color: palette.secondaryText),
              )
            : null,
        trailing: isSelected
            ? Icon(Icons.check, color: theme.colorScheme.primary)
            : null,
        onTap: () => Navigator.of(context).pop(_LanguageChoice(variety)),
      );
    }

    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Semantics(
              header: true,
              child: Text(
                l10n.proofreadLanguageTitle,
                style: TranslateLayout.sectionHeadingStyle(context),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              key: const Key('proofread_languages'),
              children: [
                tile(null),
                const Hairline(indent: 72),
                for (final variety in ProofreadVariety.values) tile(variety),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
