import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/widgets/document_labels.dart';
import 'package:mozhi/documents/widgets/document_pickers.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/engine_selector.dart';

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
      return Card.outlined(
        margin: EdgeInsets.zero,
        child: ListTile(
          key: const Key('documents_no_engines'),
          leading: const Icon(Icons.translate),
          title: Text(l10n.documentsNoEngines),
        ),
      );
    }

    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key('documents_engine'),
              enabled: !locked && state.engines.isNotEmpty,
              leading: engine == null
                  ? const Icon(Icons.translate)
                  : EngineIcon(engine: engine),
              title: Text(l10n.documentsEngineLabel),
              subtitle: Text(
                engine == null
                    ? '—'
                    : [engine.name, ?engine.subtitle].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.arrow_drop_down),
              onTap: () => unawaited(_pickEngine(context)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _LanguageButton(
                      key: const Key('documents_source_language'),
                      label: documentLanguageLabel(l10n, state.source),
                      semanticLabel: l10n.documentsSourceLanguage(
                        documentLanguageLabel(l10n, state.source),
                      ),
                      onPressed: locked || state.languagesLoading
                          ? null
                          : () =>
                                unawaited(_pickLanguage(context, source: true)),
                    ),
                  ),
                  if (state.languagesLoading)
                    const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      key: const Key('documents_swap'),
                      tooltip: l10n.documentsSwap,
                      onPressed: locked || !state.canSwap
                          ? null
                          : cubit.swapLanguages,
                      icon: const Icon(Icons.swap_horiz),
                    ),
                  Expanded(
                    child: _LanguageButton(
                      key: const Key('documents_target_language'),
                      label: documentLanguageLabel(l10n, state.target),
                      semanticLabel: l10n.documentsTargetLanguage(
                        documentLanguageLabel(l10n, state.target),
                      ),
                      onPressed: locked || state.languagesLoading
                          ? null
                          : () => unawaited(
                              _pickLanguage(context, source: false),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const new({
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      excludeSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: onPressed,
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
