import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
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
          LinearProgressIndicator(
            key: const Key('documents_progress'),
            value: state.progress,
            minHeight: 6,
            borderRadius: const BorderRadius.all(Radius.circular(3)),
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
    if (state.isComplete) {
      return _Status(
        key: const Key('documents_done'),
        icon: Icons.check_circle,
        color: AppPalette.of(context).success,
        text: l10n.documentsDone,
      );
    }
    return _Status(
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
            title: Text(l10n.documentsPartLabel(index + 1)),
            subtitle: Text(describeTranslateError(l10n, error).message),
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
