import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// The translate button, or progress with a cancel button while running,
/// then the outcome (complete / parts missing).
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
          LinearProgressIndicator(
            key: const Key('documents_progress'),
            value: state.progress,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
            backgroundColor: AppPalette.of(context).hairline,
            semanticsLabel: l10n.documentsProgress(
              state.doneChunks,
              state.chunkCount,
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.documentsProgress(state.doneChunks, state.chunkCount),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppPalette.of(context).secondaryText,
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('documents_cancel'),
                style: OutlinedButton.styleFrom(
                  shape: const StadiumBorder(),
                  side: BorderSide(color: AppPalette.of(context).hairline),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (translated && state.isComplete)
          _Status(
            key: const Key('documents_done'),
            icon: Icons.check_circle,
            color: AppPalette.of(context).success,
            text: l10n.documentsDone,
          ),
        if (translated && !state.isComplete)
          _Status(
            key: const Key('documents_pending'),
            icon: Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
            text: l10n.documentsPending(state.pendingChunks),
            action: TextButton(
              key: const Key('documents_retry_all'),
              onPressed: state.canTranslate
                  ? () => unawaited(cubit.retryFailed())
                  : null,
              child: Text(l10n.documentsRetryAll),
            ),
          ),
        FilledButton.icon(
          key: const Key('documents_translate'),
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            minimumSize: const Size(0, 52),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          onPressed: state.canTranslate
              ? () => unawaited(cubit.translate())
              : null,
          icon: const Icon(Icons.translate),
          label: Text(
            state.hasTranslation
                ? l10n.documentsTranslateAgain
                : l10n.documentsTranslate,
          ),
        ),
      ],
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
    return Row(
      spacing: 8,
      children: [
        Icon(icon, color: color),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        ?action,
      ],
    );
  }
}

/// How many translation requests retrying the failed parts makes at most
/// (a part whose batch cannot be split back is translated unit by unit):
/// what a one-time consent covers.
int documentRequests(DocumentTranslateState state) {
  final chunks = state.plan?.chunks ?? const [];
  var requests = 0;
  for (final index in state.failures.keys) {
    final units = index < chunks.length ? chunks[index].units.length : 1;
    requests += 1 + (units > 1 ? units : 0);
  }
  return requests < 1 ? 1 : requests;
}

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
          onGranted: () => unawaited(cubit.retryFailed()),
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
              l10n.documentsFailedTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
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
              l10n.documentsPartLabel(index + 1),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              describeTranslateError(l10n, error).message,
              style: TextStyle(color: AppPalette.of(context).secondaryText),
            ),
            trailing: IconButton(
              tooltip: l10n.documentsRetryPart(index + 1),
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
