import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Export actions for the translation: share as file, save, copy, and the
/// bilingual option for subtitles.
class DocumentActions extends StatelessWidget {
  const new({super.key});

  Rect? _origin(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;
    if (!state.hasTranslation) return const SizedBox.shrink();
    final writing = state.pdf?.writing ?? false;
    final enabled = !state.isTranslating && !writing;
    final palette = AppPalette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (state.supportsBilingual)
          SwitchListTile(
            key: const Key('documents_bilingual'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.documentsBilingual),
            subtitle: Text(l10n.documentsBilingualHint),
            value: state.bilingual,
            onChanged: (value) => cubit.setBilingual(enabled: value),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('documents_save'),
              onPressed: enabled ? () => unawaited(cubit.save()) : null,
              icon: const Icon(Icons.save_alt),
              label: Text(l10n.documentsSave),
            ),
            if (cubit.canShareFiles)
              Builder(
                builder: (context) => OutlinedButton.icon(
                  key: const Key('documents_share'),
                  onPressed: enabled
                      ? () => unawaited(cubit.share(origin: _origin(context)))
                      : null,
                  icon: const Icon(Icons.share_outlined),
                  label: Text(l10n.documentsShareFile),
                ),
              ),
            // A PDF's translation as plain text, page by page.
            if (state.isPdf)
              OutlinedButton.icon(
                key: const Key('documents_save_text'),
                onPressed: enabled
                    ? () => unawaited(
                        cubit.saveText(pageHeading: l10n.documentsPdfPageLabel),
                      )
                    : null,
                icon: const Icon(Icons.text_snippet_outlined),
                label: Text(l10n.documentsPdfSaveText),
              ),
            OutlinedButton.icon(
              key: const Key('documents_copy'),
              onPressed: enabled ? () => unawaited(cubit.copy()) : null,
              icon: const Icon(Icons.copy_outlined),
              label: Text(l10n.documentsCopyText),
            ),
          ],
        ),
        if (writing)
          Semantics(
            key: const Key('documents_pdf_writing'),
            liveRegion: true,
            child: Row(
              spacing: 12,
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                Expanded(
                  child: Text(
                    l10n.documentsPdfWriting,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        Text(
          l10n.documentsOutputName(state.outputFileName),
          key: const Key('documents_output_name'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.secondaryText,
          ),
        ),
        if (state.isPdf)
          Text(
            l10n.documentsPdfTextFileName(state.pdfTextFileName),
            key: const Key('documents_pdf_text_name'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.secondaryText,
            ),
          ),
        if (!state.isComplete && !state.isTranslating)
          Text(
            state.isPdf
                ? l10n.documentsPdfPartialWarning
                : l10n.documentsPartialWarning,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
      ],
    );
  }
}
