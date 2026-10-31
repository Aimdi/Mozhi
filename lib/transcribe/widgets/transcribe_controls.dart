import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/transcribe/cubit/transcribe_cubit.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/browser_speech_notice.dart';

/// The bottom of Transcribe: the status ("Listening…", phrases being
/// transcribed, ...), a large microphone that starts, pauses and resumes,
/// and Stop.
class TranscribeControls extends StatelessWidget {
  const new({super.key});

  /// Starts (or resumes) transcribing; with the browser's speech
  /// recognition, only once the user has accepted its notice
  /// ([confirmBrowserSpeech]), as for dictation.
  static Future<void> _start(
    BuildContext context,
    TranscribeCubit cubit,
    TranscribeMode mode,
  ) async {
    if (mode == TranscribeMode.system) {
      SpeechInputService? service;
      try {
        service = context.read<SpeechInputService>();
      } on ProviderNotFoundException {
        service = null;
      }
      if (service != null && !await confirmBrowserSpeech(context, service)) {
        return;
      }
    }
    await cubit.start();
  }

  /// Diameter of the microphone button.
  static const double micSize = 72;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final cubit = context.read<TranscribeCubit>();
    final state = context.watch<TranscribeCubit>().state;
    final status = state.status;
    final recording = state.isRecording;
    final paused = status == TranscribeStatus.paused;
    final starting = status == TranscribeStatus.starting;
    final label = switch (status) {
      TranscribeStatus.loading ||
      TranscribeStatus.starting => l10n.transcribeStatusStarting,
      TranscribeStatus.listening when state.heardSpeech =>
        l10n.transcribeStatusHearing,
      TranscribeStatus.listening => l10n.transcribeStatusListening,
      TranscribeStatus.paused
          when state.pauseReason == TranscribePauseReason.background =>
        l10n.transcribeStatusBackground,
      TranscribeStatus.paused => l10n.transcribeStatusPaused,
      TranscribeStatus.idle => l10n.transcribeStatusIdle,
    };
    final tooltip = recording
        ? l10n.transcribePause
        : paused
        ? l10n.transcribeResume
        : l10n.transcribeStart;
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                label,
                key: const Key('transcribe_status'),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: palette.secondaryText,
                ),
              ),
            ),
            if (state.pending > 0) ...[
              const SizedBox(height: 4),
              Text(
                l10n.transcribePending(state.pending),
                key: const Key('transcribe_pending'),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: palette.secondaryText,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Keeps the microphone centred.
                const SizedBox(width: 56),
                SizedBox.square(
                  dimension: micSize,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      if (state.isListening) _LevelRing(level: state.level),
                      if (starting)
                        const SizedBox.square(
                          dimension: micSize - 4,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      IconButton(
                        key: const Key('transcribe_mic'),
                        tooltip: tooltip,
                        isSelected: recording,
                        iconSize: 32,
                        style: IconButton.styleFrom(
                          fixedSize: const Size.square(micSize),
                          backgroundColor: scheme.primary,
                          foregroundColor: scheme.onPrimary,
                        ),
                        icon: const Icon(Icons.mic),
                        selectedIcon: const Icon(Icons.pause),
                        onPressed: () => unawaited(
                          recording
                              ? cubit.pause()
                              : _start(context, cubit, state.mode),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: recording || paused
                      ? IconButton(
                          key: const Key('transcribe_stop'),
                          tooltip: l10n.transcribeStop,
                          icon: const Icon(Icons.stop_rounded),
                          onPressed: () => unawaited(cubit.stop()),
                        )
                      : null,
                ),
              ],
            ),
            if (recording) ...[
              const SizedBox(height: 8),
              Text(
                l10n.transcribeKeepsScreenOn,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.secondaryText,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A translucent circle behind the microphone, scaled by the [level]
/// (still when animations are off).
class _LevelRing extends StatelessWidget {
  const new({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: AnimatedScale(
        key: const Key('transcribe_level'),
        scale: reduceMotion ? 1.15 : 1 + 0.45 * level.clamp(0, 1),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.16),
          ),
          child: const SizedBox.square(dimension: TranscribeControls.micSize),
        ),
      ),
    );
  }
}
