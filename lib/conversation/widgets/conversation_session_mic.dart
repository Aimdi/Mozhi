import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/cubit/conversation_cubit.dart';
import 'package:mozhi/conversation/models/conversation_turn.dart';
import 'package:mozhi/conversation/widgets/conversation_session_status.dart';
import 'package:mozhi/conversation/widgets/side_colors.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/browser_speech_notice.dart';

/// The large round microphone of a hands-free conversation
/// ([ConversationCubit.toggleSession]): starts it, stops it while it runs
/// and continues it when it paused or failed.
///
/// A filled accent circle of [size] dp. While the microphone listens a
/// ring in the colour of the side listened for keeps pulsing outwards (a
/// static ring with reduced motion); while it starts, transcribes or
/// translates a thin progress ring turns around it; while the translation
/// is read aloud it shows a speaker. A paused or failed conversation shows
/// a quieter tonal circle.
///
/// In the web app, starting a conversation first says that the browser's
/// speech recognition may send the audio to the browser's maker
/// ([confirmBrowserSpeech], once).
///
/// Its semantics say what a tap does ("Start conversation", "Stop
/// conversation", "Continue conversation") and, while active, the status
/// (`conversationSessionStatus`, e.g. "Listening in Spanish…").
class ConversationSessionMic extends StatelessWidget {
  const new({this.size = defaultSize, super.key});

  /// Diameter of the regular button.
  static const double defaultSize = 80;

  /// Diameter of the button in a compact dock.
  static const double compactSize = 56;

  /// Key of the button.
  static const Key buttonKey = Key('conversation_session_mic');

  /// Key of the ring that pulses while listening.
  static const Key pulseKey = Key('conversation_session_pulse');

  /// Key of the progress ring (starting, transcribing, translating).
  static const Key progressKey = Key('conversation_session_progress');

  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<ConversationCubit>().state;
    final session = state.session;
    final label = switch (session) {
      ConversationSessionIdle() => l10n.conversationSessionStart,
      ConversationSessionPaused() ||
      ConversationSessionFailed() => l10n.conversationSessionContinue,
      _ => l10n.conversationSessionStop,
    };
    final status = session.isActive
        ? conversationSessionStatus(l10n, state)
        : null;
    final quiet = session.isActive && !session.isRunning;
    final listening = switch (session) {
      ConversationSessionListening(stage: ConversationListenStage.listening) =>
        true,
      _ => false,
    };
    final busy = switch (session) {
      ConversationSessionListening(:final stage) =>
        stage != ConversationListenStage.listening,
      ConversationSessionTranslating() => true,
      _ => false,
    };
    final speaking = session is ConversationSessionSpeaking;
    final side = session.side ?? ConversationSide.a;
    final ring = ConversationSideColors.of(context, side).accent;
    final icon = switch (session) {
      ConversationSessionSpeaking() => Icons.volume_up_rounded,
      ConversationSessionFailed() => Icons.mic_off_outlined,
      _ => Icons.mic,
    };

    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        value: status,
        excludeSemantics: true,
        onTap: () => unawaited(_toggle(context)),
        child: SizedBox.square(
          dimension: size + 16,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (listening || speaking)
                _PulseRing(key: pulseKey, size: size, color: ring),
              if (busy)
                IgnorePointer(
                  child: SizedBox.square(
                    key: progressKey,
                    dimension: size + 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: ring,
                    ),
                  ),
                ),
              IconButton(
                key: buttonKey,
                iconSize: size * 0.45,
                style: IconButton.styleFrom(
                  fixedSize: Size.square(size),
                  backgroundColor: quiet
                      ? scheme.secondaryContainer
                      : scheme.primary,
                  foregroundColor: quiet
                      ? scheme.onSecondaryContainer
                      : scheme.onPrimary,
                ),
                icon: Icon(icon),
                onPressed: () => unawaited(_toggle(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Starts, stops or continues the conversation; a start in the web app
/// waits for the browser notice ([confirmBrowserSpeech]).
Future<void> _toggle(BuildContext context) async {
  final cubit = context.read<ConversationCubit>();
  if (!cubit.state.session.isActive) {
    if (_speechInputOf(context) case final service?
        when !await confirmBrowserSpeech(context, service)) {
      return;
    }
    if (cubit.isClosed) return;
  }
  await cubit.toggleSession();
}

SpeechInputService? _speechInputOf(BuildContext context) {
  try {
    return context.read<SpeechInputService>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// A ring in [color] that keeps pulsing outwards; a static ring when
/// animations are disabled.
class _PulseRing extends StatefulWidget {
  const new({required this.size, required this.color, super.key});

  final double size;
  final Color color;

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: widget.color, width: 3),
      ),
      child: SizedBox.square(dimension: widget.size),
    );
    if (_reduceMotion) {
      return IgnorePointer(child: Transform.scale(scale: 1.12, child: ring));
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeOut.transform(_controller.value);
          return Transform.scale(
            scale: 1 + 0.35 * t,
            child: Opacity(opacity: (1 - t) * 0.8, child: child),
          );
        },
        child: ring,
      ),
    );
  }
}
