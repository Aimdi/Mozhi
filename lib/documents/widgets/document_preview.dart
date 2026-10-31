import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/widgets/document_pdf_preview.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Longest text the tabbed preview shows (large documents stay fast; the
/// full text is in the exported file).
const documentPreviewLimit = 20000;

/// Original / translation tabs (narrow layouts).
class DocumentPreviewTabs extends StatefulWidget {
  const new({super.key});

  @override
  State<DocumentPreviewTabs> createState() => _DocumentPreviewTabsState();
}

class _DocumentPreviewTabsState extends State<DocumentPreviewTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<DocumentTranslateCubit>().state;
    if (!state.hasDocument) return const SizedBox.shrink();

    // Jump to the translation once the first parts arrive.
    return BlocListener<DocumentTranslateCubit, DocumentTranslateState>(
      listenWhen: (previous, current) =>
          previous.hasTranslation != current.hasTranslation,
      listener: (context, state) =>
          _tabs.animateTo(state.hasTranslation ? 1 : 0),
      // Flat: X-style tabs over the text, hairlines instead of a card.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Hairline(),
          TabBar(
            key: const Key('documents_preview_tabs'),
            controller: _tabs,
            tabs: [
              Tab(text: l10n.documentsTabOriginal),
              Tab(text: l10n.documentsTabTranslation),
            ],
          ),
          // A PDF: its own notes and its text page by page (W7-B).
          if (state.isPdf)
            const DocumentPdfNotes()
          else if (state.isBinary)
            _OfficeHints(state: state),
          ListenableBuilder(
            listenable: _tabs,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
              child: _tabs.index == 0
                  ? state.isPdf
                        ? const DocumentPdfPages(translated: false)
                        : _PreviewText(
                            key: const Key('documents_preview_original'),
                            text: state.text,
                          )
                  : state.hasTranslation
                  ? state.isPdf
                        ? const DocumentPdfPages(translated: true)
                        : _PreviewText(
                            key: const Key('documents_preview_translation'),
                            text: state.output,
                          )
                  : _Placeholder(text: l10n.documentsPreviewEmpty),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewText extends StatelessWidget {
  const new({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final truncated = text.length > documentPreviewLimit;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        SelectableText(
          truncated ? text.substring(0, documentPreviewLimit) : text,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
        ),
        if (truncated)
          Text(
            context.l10n.documentsPreviewTruncated(
              NumberFormat.decimalPattern(locale).format(documentPreviewLimit),
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.of(context).secondaryText,
            ),
          ),
      ],
    );
  }
}

/// Says that an office document's preview is its text only.
/// Notes about an office document or e-book: the preview shows its text
/// only, and the translated file keeps its macros (when it has some).
class _OfficeHints extends StatelessWidget {
  const new({required this.state});

  final DocumentTranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hint(
          key: const Key('documents_preview_text_only'),
          text: l10n.documentsPreviewTextOnly,
        ),
        if (state.keepsMacros)
          _Hint(
            key: const Key('documents_keeps_macros'),
            text: l10n.documentsKeepsMacros,
          ),
      ],
    );
  }
}

/// A short note about the document.
class _Hint extends StatelessWidget {
  const new({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppPalette.of(context).secondaryText,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const new({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: AppPalette.of(context).secondaryText,
        ),
      ),
    );
  }
}

/// Bilingual side-by-side view (wide layouts): one row per segment with
/// the original on the left and its translation on the right.
class DocumentSideBySide extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<DocumentTranslateCubit>().state;
    // A PDF's paragraphs, page by page (W7-B).
    if (state.isPdf) return const DocumentPdfSideBySide();
    final segments = state.segments;
    if (!state.hasDocument || segments.isEmpty) {
      return Center(
        // Before a document is chosen, the controls show how to pick one.
        child: _Placeholder(
          text: state.hasDocument
              ? l10n.documentsErrorNothing
              : l10n.documentsPreviewEmpty,
        ),
      );
    }
    final palette = AppPalette.of(context);
    final header = theme.textTheme.titleSmall;

    // A flat card: hairline outline, no fill.
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: palette.hairline),
        borderRadius: AppLook.of(context).cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              spacing: 16,
              children: [
                Expanded(child: Text(l10n.documentsTabOriginal, style: header)),
                Expanded(
                  child: Text(l10n.documentsTabTranslation, style: header),
                ),
              ],
            ),
          ),
          const Hairline(),
          if (state.isBinary)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _OfficeHints(state: state),
            ),
          Expanded(
            child: ListView.separated(
              key: const Key('documents_side_by_side'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: segments.length,
              separatorBuilder: (_, _) => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Hairline(indent: 16),
              ),
              itemBuilder: (context, index) {
                final translation = index < state.translations.length
                    ? state.translations[index]
                    : null;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 16,
                    children: [
                      Expanded(
                        child: SelectableText(state.segmentSource(index)),
                      ),
                      Expanded(
                        child: translation == null
                            ? Text(
                                '…',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.secondaryText,
                                ),
                              )
                            : SelectableText(
                                state.segmentOutput(index, translation),
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
