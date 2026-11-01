import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/language_pair_bar.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/widgets/document_labels.dart';
import 'package:mozhi/documents/widgets/document_pickers.dart';
import 'package:mozhi/documents/widgets/document_progress_section.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';

/// Engine and language selection for the document, and the go button
/// ([DocumentTranslateButton]) at the end of the language bar, like the
/// translate screen's.
class DocumentSettingsCard extends StatelessWidget {
  const new({super.key});

  Future<void> _pickEngine(BuildContext context) async {
    final cubit = context.read<DocumentTranslateCubit>();
    final engine = await showDocumentEnginePicker(
      context,
      engines: cubit.state.engines,
      selected: cubit.state.engine,
    );
    if (engine != null) await cubit.selectEngine(engine);
  }

  Future<void> _pickLanguage(
    BuildContext context, {
    required bool source,
  }) async {
    final l10n = context.l10n;
    final cubit = context.read<DocumentTranslateCubit>();
    final state = cubit.state;
    final language = await showDocumentLanguagePicker(
      context,
      title: source ? l10n.documentsPickSource : l10n.documentsPickTarget,
      languages: source ? state.sourceLanguages : state.targetLanguages,
      selected: source ? state.source : state.target,
      allowCustom: !source && (state.engine?.supportsCustomLanguages ?? false),
    );
    if (language == null) return;
    if (source) {
      cubit.setSource(language);
    } else {
      cubit.setTarget(language);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;
    final engine = state.engine;
    final locked = state.isTranslating;

    if (state.engines.isEmpty && engine == null) {
      return ListTile(
        key: const Key('documents_no_engines'),
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.translate),
        title: Text(l10n.documentsNoEngines),
      );
    }

    final sourceLabel = documentLanguageLabel(l10n, state.source);
    final targetLabel = documentLanguageLabel(l10n, state.target);
    final pickable = !locked && !state.languagesLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        ListTile(
          key: const Key('documents_engine'),
          contentPadding: const EdgeInsetsDirectional.only(start: 4, end: 4),
          enabled: !locked && state.engines.isNotEmpty,
          leading: engine == null
              ? const Icon(Icons.translate)
              : EngineIcon(engine: engine),
          title: Text(l10n.documentsEngineLabel),
          subtitle: Text(
            engine == null ? '—' : [engine.name, ?engine.subtitle].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(
            Icons.expand_more,
            color: AppPalette.of(context).secondaryText,
          ),
          onTap: () => unawaited(_pickEngine(context)),
        ),
        LanguagePairBar(
          key: const Key('documents_language_bar'),
          source: LanguagePairSide(
            key: const Key('documents_source_language'),
            label: sourceLabel,
            semanticLabel: l10n.documentsSourceLanguage(sourceLabel),
            icon: state.source.isCustom ? Icons.auto_awesome_outlined : null,
            forms: languagePairForms(
              state.source,
              label: sourceLabel,
              autoShort: l10n.translateDetectLanguageShort,
              icon: state.source.isCustom ? Icons.auto_awesome_outlined : null,
            ),
            onPressed: pickable
                ? () => unawaited(_pickLanguage(context, source: true))
                : null,
          ),
          target: LanguagePairSide(
            key: const Key('documents_target_language'),
            label: targetLabel,
            semanticLabel: l10n.documentsTargetLanguage(targetLabel),
            icon: state.target.isCustom ? Icons.auto_awesome_outlined : null,
            forms: languagePairForms(
              state.target,
              label: targetLabel,
              autoShort: l10n.translateDetectLanguageShort,
              icon: state.target.isCustom ? Icons.auto_awesome_outlined : null,
            ),
            onPressed: pickable
                ? () => unawaited(_pickLanguage(context, source: false))
                : null,
          ),
          middle: state.languagesLoading
              ? const LanguagePairProgress()
              : LanguageSwapButton(
                  key: const Key('documents_swap'),
                  tooltip: l10n.documentsSwap,
                  onPressed: locked || !state.canSwap
                      ? null
                      : cubit.swapLanguages,
                ),
          trailing: const [DocumentTranslateButton()],
        ),
      ],
    );
  }
}
