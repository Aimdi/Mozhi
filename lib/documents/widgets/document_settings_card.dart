import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/widgets/document_labels.dart';
import 'package:mozhi/documents/widgets/document_pickers.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';
import 'package:translation_repository/translation_repository.dart';

/// Engine and language selection for the document.
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

    final palette = AppPalette.of(context);
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
          title: Text(
            l10n.documentsEngineLabel,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            engine == null ? '—' : [engine.name, ?engine.subtitle].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.secondaryText),
          ),
          trailing: Icon(Icons.expand_more, color: palette.secondaryText),
          onTap: () => unawaited(_pickEngine(context)),
        ),
        Row(
          children: [
            Expanded(
              child: _LanguageButton(
                key: const Key('documents_source_language'),
                language: state.source,
                label: documentLanguageLabel(l10n, state.source),
                semanticLabel: l10n.documentsSourceLanguage(
                  documentLanguageLabel(l10n, state.source),
                ),
                onPressed: locked || state.languagesLoading
                    ? null
                    : () => unawaited(_pickLanguage(context, source: true)),
              ),
            ),
            if (state.languagesLoading)
              Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    backgroundColor: palette.hairline,
                  ),
                ),
              )
            else
              IconButton(
                key: const Key('documents_swap'),
                tooltip: l10n.documentsSwap,
                color: Theme.of(context).colorScheme.primary,
                onPressed: locked || !state.canSwap
                    ? null
                    : cubit.swapLanguages,
                icon: const Icon(Icons.swap_horiz),
              ),
            Expanded(
              child: _LanguageButton(
                key: const Key('documents_target_language'),
                language: state.target,
                label: documentLanguageLabel(l10n, state.target),
                semanticLabel: l10n.documentsTargetLanguage(
                  documentLanguageLabel(l10n, state.target),
                ),
                onPressed: locked || state.languagesLoading
                    ? null
                    : () => unawaited(_pickLanguage(context, source: false)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// An outlined hairline pill with the language's avatar.
class _LanguageButton extends StatelessWidget {
  const new({
    required this.language,
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    super.key,
  });

  final Language language;
  final String label;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Semantics(
      label: semanticLabel,
      button: true,
      excludeSemantics: true,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          side: BorderSide(color: palette.hairline),
          shape: const StadiumBorder(),
          padding: const EdgeInsetsDirectional.fromSTEB(6, 6, 12, 6),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            if (language.isCustom)
              const Icon(Icons.auto_awesome_outlined, size: 20)
            else
              LanguageAvatar(code: language.code, size: 28),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
