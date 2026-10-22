import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/cubit/practice_speech_cubit.dart';
import 'package:mozhi/practice/data/practice_speech.dart';

/// The microphone of speaking practice ([PracticeSpeechCubit]): hold it
/// and say the phrase (it stops when let go), or tap to start and tap
/// again to stop; Enter or Space and a screen reader's double tap toggle
/// it too. While it listens, a ring follows the voice (a plain ring with
/// reduced motion). Below it says what it is doing.
class SpeakingButton extends StatefulWidget {
  const new({required this.expected, required this.languageCode, super.key});

  /// The phrase the user should say, and its language.
  final String expected;
  final String languageCode;

  /// Held at least this long, letting go stops (shorter: a tap, which
  /// keeps listening until the next tap).
  static const holdThreshold = Duration(milliseconds: 400);

  @override
  State<SpeakingButton> createState() => _SpeakingButtonState();
}

class _SpeakingButtonState extends State<SpeakingButton> {
  /// When the pointer went down ([PointerEvent.timeStamp]).
  Duration? _downAt;
  bool _stoppedOnDown = false;

  PracticeSpeechCubit get _cubit => context.read<PracticeSpeechCubit>();

  bool get _listening => _cubit.state.status == PracticeSpeechStatus.listening;

  void _start() => unawaited(
    _cubit.listen(expected: widget.expected, code: widget.languageCode),
  );

  void _toggle() {
    if (_listening) {
      unawaited(_cubit.stop());
    } else if (_cubit.state.canListen) {
      _start();
    }
  }

  void _down(PointerDownEvent event) {
    if (_listening) {
      _stoppedOnDown = true;
      unawaited(_cubit.stop());
      return;
    }
    _stoppedOnDown = false;
    if (!_cubit.state.canListen) return;
    _downAt = event.timeStamp;
    _start();
  }

  void _up(PointerEvent event) {
    final downAt = _downAt;
    _downAt = null;
    if (_stoppedOnDown || downAt == null) return;
    if (event.timeStamp - downAt >= SpeakingButton.holdThreshold) {
      unawaited(_cubit.stop());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final state = context.watch<PracticeSpeechCubit>().state;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final listening = state.status == PracticeSpeechStatus.listening;
    final transcribing = state.status == PracticeSpeechStatus.transcribing;
    final enabled = state.canListen || listening;
    final label = listening ? l10n.practiceSpeakStop : l10n.practiceSpeak;
    final status = switch (state.status) {
      PracticeSpeechStatus.listening => l10n.practiceListening,
      PracticeSpeechStatus.transcribing => l10n.practiceTranscribing,
      PracticeSpeechStatus.failed => switch (state.failure) {
        PracticeSpeechFailure.noSpeech => l10n.practiceHeardNothing,
        PracticeSpeechFailure.permissionDenied => l10n.practiceSpeechPermission,
        _ => l10n.practiceSpeechFailed,
      },
      _ => null,
    };
    const size = 64.0;
    final ring = listening ? (reduceMotion ? 6.0 : 4 + 14 * state.level) : 0.0;
    final button = AnimatedContainer(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 90),
      width: size + 2 * ring,
      height: size + 2 * ring,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: listening
            ? colors.primary.withValues(alpha: 0.18)
            : Colors.transparent,
      ),
      child: Material(
        shape: const CircleBorder(),
        color: listening ? colors.primary : colors.primaryContainer,
        child: SizedBox.square(
          dimension: size,
          child: transcribing
              ? Padding(
                  padding: const EdgeInsets.all(18),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: colors.onPrimaryContainer,
                  ),
                )
              : Icon(
                  listening ? Icons.stop_rounded : Icons.mic_none_rounded,
                  size: 32,
                  color: listening
                      ? colors.onPrimary
                      : colors.onPrimaryContainer,
                ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: l10n.practiceSpeakHint,
          excludeFromSemantics: true,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: label,
            hint: l10n.practiceSpeakHint,
            onTap: enabled ? _toggle : null,
            excludeSemantics: true,
            child: FocusableActionDetector(
              key: const Key('practice_speak'),
              enabled: enabled,
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
              },
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    _toggle();
                    return null;
                  },
                ),
              },
              child: Listener(
                onPointerDown: enabled ? _down : null,
                onPointerUp: _up,
                onPointerCancel: _up,
                child: SizedBox.square(
                  dimension: size + 36,
                  child: Center(child: button),
                ),
              ),
            ),
          ),
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: state.status == PracticeSpeechStatus.failed
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
