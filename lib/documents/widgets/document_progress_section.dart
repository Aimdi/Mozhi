import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/core/core.dart' show Chunker, DocumentFormat;
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/pdf/pdf.dart'
    show PdfRenderException, PdfSource, PdfStage;
import 'package:mozhi/image_translate/models/models.dart'
    show ImageTranslateException, OcrDataMissingException;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/view/on_device_ai_paused_notice.dart';
import 'package:mozhi/translate/widgets/personal_data_kept_note.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// The go button of the document (the translate screen's rocket, at the
/// end of the language bar): translates the document, or translates it
/// again once there is a translation. Disabled while there is nothing to
/// translate; a progress ring turns around it while translating.
class DocumentTranslateButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (canTranslate, hasTranslation, translating) = context
        .select<DocumentTranslateCubit, (bool, bool, bool)>(
          (cubit) => (
            cubit.state.canTranslate,
            cubit.state.hasTranslation,
            cubit.state.isTranslating,
          ),
        );
    return ComposerGoButton(
      key: const Key('documents_translate'),
      label: hasTranslation
          ? l10n.documentsTranslateAgain
          : l10n.documentsTranslate,
      busy: translating,
      onPressed: canTranslate
          ? () => unawaited(context.read<DocumentTranslateCubit>().translate())
          : null,
    );
  }
}

/// Progress with a cancel button while translating, then the outcome
/// (complete / parts missing, with a retry). The translate button itself
/// is the language bar's [DocumentTranslateButton].
class DocumentProgressSection extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;

    if (state.isTranslating) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          // On-device AI waits between the chunks while the phone is hot
          // or saving battery (shows nothing otherwise).
          OnDeviceAiPausedNotice(onCancel: cubit.cancel),
          LinearProgressIndicator(
            key: const Key('documents_progress'),
            value: state.progress,
            minHeight: 6,
            borderRadius: const BorderRadius.all(Radius.circular(3)),
            semanticsLabel: state.isPdf
                ? l10n.documentsPdfProgress(state.doneChunks, state.chunkCount)
                : l10n.documentsProgress(state.doneChunks, state.chunkCount),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  // A PDF: the page being read or translated.
                  state.isPdf
                      ? documentPdfProgressLabel(l10n, state)
                      : l10n.documentsProgress(
                          state.doneChunks,
                          state.chunkCount,
                        ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppPalette.of(context).secondaryText,
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('documents_cancel'),
                onPressed: cubit.cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(l10n.commonCancel),
              ),
            ],
          ),
        ],
      );
    }

    final translated = state.status == DocumentStatus.translated;
    if (!translated) return const SizedBox.shrink();
    // Personal data the shield kept on the device, like the translate
    // screen's note.
    final kept = PersonalDataKeptNote(
      key: const Key('documents_personal_data_kept'),
      count: state.maskedPersonalData,
    );
    final Widget status;
    if (state.isComplete) {
      status = _Status(
        key: const Key('documents_done'),
        icon: Icons.check_circle,
        color: AppPalette.of(context).success,
        text: l10n.documentsDone,
      );
    } else {
      status = _pending(context, state);
    }
    if (state.maskedPersonalData <= 0) return status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [status, kept],
    );
  }

  Widget _pending(BuildContext context, DocumentTranslateState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<DocumentTranslateCubit>();
    return _Status(
      key: const Key('documents_pending'),
      icon: Icons.warning_amber_rounded,
      color: theme.colorScheme.error,
      text: state.isPdf
          ? l10n.documentsPdfPending(state.pendingChunks)
          : l10n.documentsPending(state.pendingChunks),
      action: TextButton(
        key: const Key('documents_retry_all'),
        onPressed: state.canTranslate
            ? () => unawaited(cubit.retryFailed())
            : null,
        child: Text(
          state.isPdf ? l10n.documentsPdfRetryAll : l10n.documentsRetryAll,
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const new({
    required this.icon,
    required this.color,
    required this.text,
    this.action,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      spacing: 8,
      children: [
        Icon(icon, color: color),
        Expanded(child: Text(text, style: theme.textTheme.titleSmall)),
        ?action,
      ],
    );
  }
}

/// How many translation requests retrying the failed parts makes at most
/// (a part whose batch cannot be split back is translated unit by unit):
/// what a one-time consent covers. What the run does not use is withdrawn
/// when it ends (`DocumentTranslateCubit.consentGranted`).
int documentRequests(DocumentTranslateState state) {
  if (state.pdf case final pdf?) return _pdfRequests(state, pdf);
  final chunks = state.plan?.chunks ?? const [];
  var requests = 0;
  for (final index in state.failures.keys) {
    final units = index < chunks.length ? chunks[index].units.length : 1;
    requests += 1 + (units > 1 ? units : 0);
  }
  return requests < 1 ? 1 : requests;
}

/// [documentRequests] of a PDF: the pages still missing (failed or never
/// reached) with what is known of them: a read page's chunks that are not
/// done (each perhaps unit by unit), an unread page's
/// [_requestsPerUnreadPage].
int _pdfRequests(DocumentTranslateState state, PdfSource pdf) {
  const chunker = Chunker();
  var requests = 0;
  for (var index = 0; index < pdf.pageCount; index++) {
    if (state.results.containsKey(index)) continue;
    final page = pdf.pages[index];
    if (page == null) {
      requests += _requestsPerUnreadPage;
      continue;
    }
    final done = pdf.partial[index] ?? const {};
    final plan = chunker.planSegments(
      page.segments,
      Chunker.encodingFor(DocumentFormat.pdf),
    );
    for (final chunk in plan.chunks) {
      if (done.containsKey(chunk.index)) continue;
      requests += 1 + (chunk.units.length > 1 ? chunk.units.length : 0);
    }
  }
  return requests < 1 ? 1 : requests;
}

/// What a page not read yet is counted as: most pages are one or two
/// requests, and what the run does not use is withdrawn when it ends.
const _requestsPerUnreadPage = 3;

/// "Page 3 of 12: reading the text…", "Page 3 of 12: translating…",
/// "Page 3 of 12: the phone is hot…" while text recognition waits, or
/// between pages "2 of 12 pages done".
String documentPdfProgressLabel(
  AppLocalizations l10n,
  DocumentTranslateState state,
) {
  final pdf = state.pdf;
  final page = pdf?.currentPage;
  final total = state.chunkCount;
  return switch (pdf?.stage) {
    PdfStage.reading when page != null => l10n.documentsPdfProgressReading(
      page + 1,
      total,
    ),
    PdfStage.translating when page != null =>
      l10n.documentsPdfProgressTranslating(page + 1, total),
    PdfStage.cooling when page != null => l10n.documentsPdfProgressCooling(
      page + 1,
      total,
    ),
    _ => l10n.documentsPdfProgress(state.doneChunks, total),
  };
}

/// Why page [error] of a PDF failed: a page that could not be read, or the
/// translation's error.
String _pdfFailure(AppLocalizations l10n, Object error) => switch (error) {
  PdfRenderException() ||
  ImageTranslateException() ||
  OcrDataMissingException() => l10n.documentsPdfPageReadFailed,
  _ => describeTranslateError(l10n, error).message,
};

/// Chunks that failed, each with its error and a retry button. When the
/// privacy settings stopped them, the consent prompt instead.
class DocumentFailuresCard extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;
    final failures = state.failures.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (failures.isEmpty) return const SizedBox.shrink();
    final consent = failures
        .map((entry) => entry.value)
        .whereType<ConsentRequiredException>()
        .firstOrNull;
    if (consent != null) {
      // Nothing was sent: once allowed, the failed parts are translated.
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: ConsentInlinePrompt(
          key: const Key('documents_consent'),
          consent: consent,
          requests: documentRequests(state),
          onGranted: () => unawaited(cubit.consentGranted()),
        ),
      );
    }

    return Column(
      key: const Key('documents_failures'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Hairline(),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          child: Semantics(
            header: true,
            child: Text(
              state.isPdf
                  ? l10n.documentsPdfFailedTitle
                  : l10n.documentsFailedTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ),
        for (final (position, MapEntry(key: index, value: error))
            in failures.indexed) ...[
          if (position > 0) const Hairline(indent: 56),
          ListTile(
            key: Key('documents_failure_$index'),
            contentPadding: const EdgeInsetsDirectional.only(start: 4),
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: Text(
              state.isPdf
                  ? l10n.documentsPdfPageLabel(index + 1)
                  : l10n.documentsPartLabel(index + 1),
            ),
            subtitle: Text(
              state.isPdf
                  ? _pdfFailure(l10n, error)
                  : describeTranslateError(l10n, error).message,
            ),
            trailing: IconButton(
              tooltip: state.isPdf
                  ? l10n.documentsPdfRetryPage(index + 1)
                  : l10n.documentsRetryPart(index + 1),
              color: theme.colorScheme.primary,
              onPressed: state.canTranslate
                  ? () => unawaited(cubit.retryChunk(index))
                  : null,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ],
        const Hairline(),
      ],
    );
  }
}
