import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';

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
                  style: theme.textTheme.bodyMedium,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (translated && state.isComplete)
          _Status(
            key: const Key('documents_done'),
            icon: Icons.check_circle_outline,
            color: theme.colorScheme.primary,
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
        Expanded(child: Text(text)),
        ?action,
      ],
    );
  }
}

/// Chunks that failed, each with its error and a retry button.
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

    return Card.outlined(
      key: const Key('documents_failures'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                l10n.documentsFailedTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            for (final MapEntry(key: index, value: error) in failures)
              ListTile(
                key: Key('documents_failure_$index'),
                leading: Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                ),
                title: Text(l10n.documentsPartLabel(index + 1)),
                subtitle: Text(describeTranslateError(l10n, error).message),
                trailing: IconButton(
                  tooltip: l10n.documentsRetryPart(index + 1),
                  onPressed: state.canTranslate
                      ? () => unawaited(cubit.retryChunk(index))
                      : null,
                  icon: const Icon(Icons.refresh),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
