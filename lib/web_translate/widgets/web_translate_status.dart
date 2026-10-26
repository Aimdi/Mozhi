import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/view/on_device_ai_paused_notice.dart';
import 'package:mozhi/web_translate/cubit/web_translate_cubit.dart';
import 'package:mozhi/web_translate/widgets/web_translate_messages.dart';
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// How many translation requests the rest of the page needs at most (one
/// per untranslated block and the title): what a one-time consent covers.
int webTranslateRequests(WebTranslateState state) {
  final missing = state.totalItems - state.doneItems;
  return missing < 1 ? 1 : missing;
}

/// Loading / translating progress (with a stop button), the stopped state
/// (with "continue"), errors (with retry) and "no engine" information.
class WebTranslateStatusPanel extends StatelessWidget {
  const new({required this.onRetryLoad, super.key});

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
            // On-device AI waits between the parts while the phone is
            // hot or saving battery (shows nothing otherwise).
            OnDeviceAiPausedNotice(onCancel: () => unawaited(cubit.cancel())),
            LinearProgressIndicator(
              value: state.totalItems == 0 ? null : state.progress,
              borderRadius: const BorderRadius.all(Radius.circular(4)),
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

      case WebTranslateStatus.failure
          when state.error is ConsentRequiredException:
        // Nothing was sent: once allowed, the page is translated.
        return ConsentInlinePrompt(
          key: const Key('web_translate_consent'),
          consent: state.error! as ConsentRequiredException,
          requests: webTranslateRequests(state),
          onGranted: () => unawaited(cubit.resume()),
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

/// A flat, hairline-outlined notice (error-tinted outline for errors)
/// with an accent icon and an optional [action] at the end.
class _Banner extends StatelessWidget {
  const new({
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
    return _OutlinedNotice(
      icon: icon,
      iconColor: error ? colors.error : colors.primary,
      outline: error
          ? colors.error.withValues(alpha: 0.5)
          : AppPalette.of(context).hairline,
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 12),
      message: message,
      action: action,
    );
  }
}

/// The notices' box: an outline, no fill, the theme's card radius.
class _OutlinedNotice extends StatelessWidget {
  const new({
    required this.icon,
    required this.iconColor,
    required this.outline,
    required this.message,
    this.padding = const EdgeInsets.all(12),
    this.action,
    super.key,
  });

  final IconData icon;
  final Color iconColor;
  final Color outline;
  final String message;
  final EdgeInsetsGeometry padding;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: outline),
        borderRadius: AppRadius.cardBorderRadius,
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
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

/// Shown before anything is loaded: the tabs' empty state ([TabHero]).
class WebTranslateEmptyState extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
      child: TabHero(
        icon: Icons.travel_explore,
        title: l10n.webTranslateHeroTitle,
        body: l10n.webTranslateHeroBody,
      ),
    );
  }
}

/// Web builds: explains the cross-origin (CORS) limitation.
class WebTranslateWebNotice extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return _OutlinedNotice(
      key: const Key('web_translate_web_notice'),
      icon: Icons.public_off,
      iconColor: Theme.of(context).colorScheme.primary,
      outline: AppPalette.of(context).hairline,
      message: context.l10n.webTranslateWebNotice,
    );
  }
}
