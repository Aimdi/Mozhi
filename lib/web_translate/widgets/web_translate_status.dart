import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/web_translate/cubit/web_translate_cubit.dart';
import 'package:mozhi/web_translate/widgets/web_translate_messages.dart';

/// Loading / translating progress (with a stop button), the stopped state
/// (with "continue"), errors (with retry) and "no engine" information.
class WebTranslateStatusPanel extends StatelessWidget {
  const WebTranslateStatusPanel({required this.onRetryLoad, super.key});

  /// Reloads the page (used when loading failed).
  final VoidCallback onRetryLoad;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<WebTranslateCubit>().state;
    final cubit = context.read<WebTranslateCubit>();

    Widget stopButton() => TextButton.icon(
      key: const Key('web_translate_stop_button'),
      onPressed: () => unawaited(cubit.cancel()),
      icon: const Icon(Icons.stop_circle_outlined),
      label: Text(l10n.commonStop),
    );

    switch (state.status) {
      case WebTranslateStatus.idle || WebTranslateStatus.translated:
        return const SizedBox.shrink();

      case WebTranslateStatus.loading:
        return Row(
          key: const Key('web_translate_loading'),
          children: [
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.webTranslateLoading)),
            stopButton(),
          ],
        );

      case WebTranslateStatus.translating:
        return Column(
          key: const Key('web_translate_progress'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: state.totalItems == 0 ? null : state.progress,
              borderRadius: BorderRadius.circular(4),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.webTranslateProgress(
                      state.doneItems,
                      state.totalItems,
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                stopButton(),
              ],
            ),
          ],
        );

      case WebTranslateStatus.stopped:
        return _Banner(
          key: const Key('web_translate_stopped'),
          icon: Icons.pause_circle_outline,
          message: l10n.webTranslateStoppedMessage(
            state.doneItems,
            state.totalItems,
          ),
          action: FilledButton.tonalIcon(
            key: const Key('web_translate_resume_button'),
            onPressed: () => unawaited(cubit.resume()),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.webTranslateResume),
          ),
        );

      case WebTranslateStatus.loaded:
        if (state.selection != null) return const SizedBox.shrink();
        return _Banner(
          key: const Key('web_translate_no_engine'),
          icon: Icons.info_outline,
          message: l10n.webTranslateNoEngine,
        );

      case WebTranslateStatus.failure:
        final canResume = state.hasPage && state.selection != null;
        return _Banner(
          key: const Key('web_translate_error'),
          icon: Icons.error_outline,
          error: true,
          message: describeWebTranslateError(l10n, state.error),
          action: TextButton.icon(
            key: const Key('web_translate_retry_button'),
            onPressed: canResume
                ? () => unawaited(cubit.resume())
                : onRetryLoad,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.commonRetry),
          ),
        );
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.message,
    this.action,
    this.error = false,
    super.key,
  });

  final IconData icon;
  final String message;
  final Widget? action;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = error
        ? colors.errorContainer
        : colors.secondaryContainer;
    final foreground = error
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: background,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: foreground),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(message, style: TextStyle(color: foreground)),
                ),
              ],
            ),
            if (action != null)
              Align(alignment: AlignmentDirectional.centerEnd, child: action),
          ],
        ),
      ),
    );
  }
}

/// Shown before anything is loaded.
class WebTranslateEmptyState extends StatelessWidget {
  const WebTranslateEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
      child: Column(
        children: [
          Icon(
            Icons.travel_explore,
            size: 56,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.webTranslateEmptyTitle,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.webTranslateEmptyBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Web builds: explains the cross-origin (CORS) limitation.
class WebTranslateWebNotice extends StatelessWidget {
  const WebTranslateWebNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('web_translate_web_notice'),
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.public_off, color: colors.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                context.l10n.webTranslateWebNotice,
                style: TextStyle(color: colors.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
