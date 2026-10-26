import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/pdf/pdf_document.dart';
import 'package:mozhi/documents/widgets/document_labels.dart';
import 'package:mozhi/documents/widgets/document_preview.dart'
    show documentPreviewLimit;
import 'package:mozhi/image_translate/widgets/ocr_language_offer.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Notes above a PDF's preview: what the preview and the saved PDF are,
/// the first page being read, the offer to get the recognition data of the
/// source language, and why pages can't be read.
class DocumentPdfNotes extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;
    final pdf = state.pdf;
    if (pdf == null) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppPalette.of(context).secondaryText,
    );
    final missing = pdf.missingData;
    final data = cubit.pdfLanguageData;
    final issue = switch (pdf.issue) {
      PdfReadIssue.languageUnsupported => l10n.documentsPdfLanguageUnsupported(
        documentLanguageLabel(l10n, state.source),
      ),
      PdfReadIssue.recognitionUnavailable =>
        l10n.documentsPdfRecognitionUnavailable,
      PdfReadIssue.readFailed => l10n.documentsPdfPageReadFailed,
      null => null,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(
            l10n.documentsPdfPreviewHint,
            key: const Key('documents_pdf_hint'),
            style: muted,
          ),
          if (pdf.previewing)
            Semantics(
              key: const Key('documents_pdf_previewing'),
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  const LinearProgressIndicator(),
                  Text(l10n.documentsPdfReadingFirstPage, style: muted),
                ],
              ),
            ),
          if (missing != null && data != null && !state.isTranslating)
            OcrLanguageOffer(
              key: ValueKey(missing),
              missing: missing,
              data: data,
              onInstalled: () => unawaited(cubit.pdfDataInstalled()),
            ),
          if (issue != null)
            Semantics(
              liveRegion: true,
              child: Text(
                issue,
                key: const Key('documents_pdf_issue'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The text of a PDF's read pages, page by page: as read, or with
/// [translated] the translation (a page not translated yet shows its
/// original). Long documents show the first [documentPreviewLimit]
/// characters.
class DocumentPdfPages extends StatelessWidget {
  const new({required this.translated, super.key});

  final bool translated;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<DocumentTranslateCubit>().state;
    final pdf = state.pdf;
    if (pdf == null) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppPalette.of(context).secondaryText,
    );
    final pages = pdf.readPages;
    final children = <Widget>[];
    var shown = 0;
    var truncated = false;
    for (final page in pages) {
      if (shown >= documentPreviewLimit) {
        truncated = true;
        break;
      }
      final text = pdfText(
        PdfSource(pageSizes: pdf.pageSizes, pages: {page.page: page}),
        state.results,
        translated: translated,
      );
      shown += text.length;
      children
        ..add(
          Semantics(
            header: true,
            child: Text(
              l10n.documentsPdfPageLabel(page.page + 1),
              style: theme.textTheme.titleSmall,
            ),
          ),
        )
        ..add(
          text.isEmpty
              ? Text(
                  // Only the first page is read before translating.
                  pages.length == 1 && page.page == 0
                      ? l10n.documentsPdfFirstPageEmpty
                      : l10n.documentsPdfPageNoText,
                  style: muted,
                )
              : SelectableText(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
        );
    }
    final unread = pdf.pageCount - pages.length;
    return Column(
      key: Key(
        'documents_pdf_pages_${translated ? 'translation' : 'original'}',
      ),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        ...children,
        if (truncated)
          Text(
            l10n.documentsPreviewTruncated(
              NumberFormat.decimalPattern(
                Localizations.localeOf(context).toLanguageTag(),
              ).format(documentPreviewLimit),
            ),
            style: muted,
          )
        else if (unread > 0 && !state.isTranslating)
          Text(
            l10n.documentsPdfMorePages(unread),
            key: const Key('documents_pdf_more_pages'),
            style: muted,
          ),
      ],
    );
  }
}

/// The wide layout's side-by-side view of a PDF: every read page with its
/// paragraphs, original on the left and translation on the right.
class DocumentPdfSideBySide extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<DocumentTranslateCubit>().state;
    final pdf = state.pdf;
    if (pdf == null) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final rows = <Widget>[];
    for (final page in pdf.readPages) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Semantics(
            header: true,
            child: Text(
              l10n.documentsPdfPageLabel(page.page + 1),
              style: theme.textTheme.titleSmall,
            ),
          ),
        ),
      );
      final translations = state.results[page.page];
      for (var i = 0; i < page.paragraphs.length; i++) {
        final translation = translations != null && i < translations.length
            ? translations[i]
            : null;
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 16,
              children: [
                Expanded(child: SelectableText(page.paragraphs[i].text)),
                Expanded(
                  child: translation == null || translation.isEmpty
                      ? Text(
                          '…',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.secondaryText,
                          ),
                        )
                      : SelectableText(translation),
                ),
              ],
            ),
          ),
        );
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: palette.hairline),
        borderRadius: AppRadius.cardBorderRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              spacing: 16,
              children: [
                Expanded(
                  child: Text(
                    l10n.documentsTabOriginal,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Expanded(
                  child: Text(
                    l10n.documentsTabTranslation,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
          const Hairline(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: DocumentPdfNotes(),
          ),
          Expanded(
            child: ListView(
              key: const Key('documents_pdf_side_by_side'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: rows,
            ),
          ),
        ],
      ),
    );
  }
}
