import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:mozhi/voice/widgets/voice_error_message.dart';

/// Receives recognised speech. Partial results ([isFinal] false) contain the
/// whole utterance so far and are replaced by later ones.
typedef VoiceInputResultCallback = void Function(
  String text, {
  required bool isFinal,
});

/// Microphone button that toggles voice input.
///
/// While listening it shows a filled mic with a ring that scales with the
/// input level, forwards recognised text to [onResult] and offers "Stop
/// listening". It renders nothing ([SizedBox.shrink]) on platforms without
/// speech recognition (Linux) and once initialising the recogniser failed
/// (no recogniser, permission denied); after a denied permission is granted
/// in the system settings it reappears when the app resumes. Failures are
/// explained in a [SnackBar].
///
/// The default constructor reads the app-wide service with
/// `context.read<SpeechInputService>()` (provide it with a
/// `RepositoryProvider<SpeechInputService>`);
/// [VoiceInputButton.standalone] takes it explicitly.
class VoiceInputButton extends StatefulWidget {
  const new({
    required this.languageCode,
    required this.onResult,
    this.preferOnDevice,
    this.onListeningChanged,
    super.key,
  }) : service = null;

  const new standalone({
    required SpeechInputService this.service,
    required this.languageCode,
    required this.onResult,
    this.preferOnDevice,
    this.onListeningChanged,
    super.key,
  });

  /// Key of the sound level ring shown while listening.
  static const ValueKey<String> levelRingKey = ValueKey('voiceInputLevelRing');

  /// Explicit service; null reads it from the context.
  final SpeechInputService? service;

  /// Mozhi code of the spoken language (`en`, `pt-BR`, ...). Null, `auto`
  /// and custom languages use the device's default recognition language.
  final String? languageCode;
  final VoiceInputResultCallback onResult;

  /// Overrides the stored "Prefer on-device speech recognition" setting.
  final bool? preferOnDevice;

  /// Called when this button starts or stops listening.
  final ValueChanged<bool>? onListeningChanged;

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton> {
  late SpeechInputService _service;
  late SpeechInputState _state;
  StreamSubscription<SpeechInputState>? _states;
  StreamSubscription<SpeechInputResult>? _results;
  late final AppLifecycleListener _lifecycle;

  bool get _listening => _state.isListening && _state.isOwnedBy(this);

  @override
  void initState() {
    super.initState();
    _attach(widget.service ?? context.read<SpeechInputService>());
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_service.refreshAvailability()),
      onHide: () {
        if (_listening) unawaited(_service.stop());
      },
    );
  }

  @override
  void didUpdateWidget(VoiceInputButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final service = widget.service ?? _service;
    if (!identical(service, _service)) {
      _detach();
      _attach(service);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _detach();
    super.dispose();
  }

  void _attach(SpeechInputService service) {
    _service = service;
    _state = service.state;
    _states = service.states.listen(_onState);
    _results = service.results.listen(_onResult);
  }

  void _detach() {
    if (_listening) unawaited(_service.cancel());
    unawaited(_states?.cancel());
    unawaited(_results?.cancel());
  }

  void _onState(SpeechInputState state) {
    if (!mounted) return;
    final wasListening = _listening;
    setState(() => _state = state);
    if (wasListening != _listening) widget.onListeningChanged?.call(_listening);
    if (state is SpeechInputError && state.isOwnedBy(this)) {
      _showError(state.failure);
    }
  }

  void _onResult(SpeechInputResult result) {
    if (!identical(result.owner, this)) return;
    widget.onResult(result.text, isFinal: result.isFinal);
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _service.stop();
      return;
    }
    final started = await _service.listen(
      widget.languageCode,
      preferOnDevice: widget.preferOnDevice,
      owner: this,
    );
    if (started || !mounted) return;
    if (_service.state case SpeechInputUnavailable(:final failure?)) {
      _showError(failure);
    }
  }

  void _showError(SpeechInputFailure failure) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final message = voiceInputErrorMessage(
      context.l10n,
      failure,
      onDevice: widget.preferOnDevice ?? _service.preferOnDevice.value,
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          showCloseIcon: failure.isPermanent,
          duration: failure.isPermanent
              ? const Duration(seconds: 8)
              : const Duration(seconds: 4),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (!_service.isPlatformSupported || _state is SpeechInputUnavailable) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final listening = _listening;
    final state = _state;
    final level = listening && state is SpeechInputListening
        ? state.level
        : 0.0;
    return SizedBox.square(
      dimension: 48,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (listening) ...[
            const _PulseRing(),
            Semantics(
              liveRegion: true,
              label: l10n.voiceInputListening,
              child: _LevelRing(level: level),
            ),
          ],
          IconButton(
            tooltip: listening ? l10n.voiceInputStop : l10n.voiceInputStart,
            isSelected: listening,
            // An accent mic; a filled accent circle while listening.
            style: listening
                ? IconButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  )
                : IconButton.styleFrom(foregroundColor: scheme.primary),
            icon: const Icon(Icons.mic_none_outlined),
            selectedIcon: const Icon(Icons.mic),
            onPressed: () => unawaited(_toggle()),
          ),
        ],
      ),
    );
  }
}

/// Translucent accent circle behind the button, scaled by the input
/// [level] (static when animations are disabled).
class _LevelRing extends StatelessWidget {
  const new({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: AnimatedScale(
        key: VoiceInputButton.levelRingKey,
        scale: reduceMotion ? 1.15 : 1 + 0.5 * level.clamp(0, 1),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary.withValues(alpha: 0.16),
          ),
          child: const SizedBox.square(dimension: 48),
        ),
      ),
    );
  }
}

/// A subtle accent ring that keeps pulsing outwards while listening;
/// nothing when animations are disabled.
class _PulseRing extends StatefulWidget {
  const new();

  /// Key of the pulsing ring.
  static const ValueKey<String> pulseKey = ValueKey('voiceInputPulseRing');

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
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
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return const SizedBox.shrink();
    }
    final color = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: AnimatedBuilder(
        key: _PulseRing.pulseKey,
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeOut.transform(_controller.value);
          return Transform.scale(
            scale: 1 + 0.7 * t,
            child: Opacity(opacity: (1 - t) * 0.6, child: child),
          );
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: const SizedBox.square(dimension: 48),
        ),
      ),
    );
  }
}
