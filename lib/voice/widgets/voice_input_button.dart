import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
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
/// While the session starts (the recogniser initialises, which may show
/// the permission prompt) it shows a progress ring and offers "Cancel
/// voice input". While listening it shows a filled mic with a ring that
/// scales with the input level, forwards recognised text to [onResult]
/// and offers "Stop listening"; while an offline engine transcribes the
/// recording it shows a progress ring and offers "Cancel transcription".
///
/// It renders nothing ([SizedBox.shrink]) on platforms without speech
/// recognition (Linux). Once initialising the recogniser failed (no
/// recogniser, permission denied) it shows a dimmed "off" mic: tapping it
/// tries again (Android asks for a denied permission again) and explains
/// what is wrong; after a denied permission is granted in the system
/// settings it is back to normal when the app resumes. Failures are
/// explained in a [SnackBar]; when an offline speech model would help, it
/// offers to open the voice input settings ([settingsLocation]) to
/// download one (with a [GoRouter] above).
///
/// With [prominent] it is a large filled accent circle
/// ([prominentSize] dp) instead of a plain 48 dp icon button, e.g. the main
/// control of an empty conversation.
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
    this.prominent = false,
    super.key,
  }) : service = null;

  const new standalone({
    required SpeechInputService this.service,
    required this.languageCode,
    required this.onResult,
    this.preferOnDevice,
    this.onListeningChanged,
    this.prominent = false,
    super.key,
  });

  /// Diameter of the [prominent] button.
  static const double prominentSize = 80;

  /// Key of the sound level ring shown while listening.
  static const ValueKey<String> levelRingKey = ValueKey('voiceInputLevelRing');

  /// Key of the ring that pulses while listening (absent with reduced
  /// motion).
  static const ValueKey<String> pulseRingKey = ValueKey('voiceInputPulseRing');

  /// Key of the progress ring shown while an offline engine transcribes.
  static const ValueKey<String> transcribingKey = ValueKey(
    'voiceInputTranscribing',
  );

  /// Key of the progress ring shown while a session starts.
  static const ValueKey<String> startingKey = ValueKey('voiceInputStarting');

  /// Location of the voice input settings (the offline speech models).
  static const String settingsLocation = voiceSettingsLocation;

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

  /// A large filled accent circle ([prominentSize]) instead of an icon.
  final bool prominent;

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

  /// An offline engine is transcribing what this button recorded.
  bool get _transcribing =>
      _state is SpeechInputTranscribing && _state.isOwnedBy(this);

  /// Counts the sessions this button started.
  int _starts = 0;

  /// The session this button is starting (until it listens or fails).
  int? _startingSession;

  bool get _starting => _startingSession != null;

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
    _startingSession = null;
    _states = service.states.listen(_onState);
    _results = service.results.listen(_onResult);
  }

  void _detach() {
    if (_listening || _transcribing || _starting) {
      unawaited(_service.cancel());
    }
    unawaited(_states?.cancel());
    unawaited(_results?.cancel());
  }

  void _onState(SpeechInputState state) {
    if (!mounted) return;
    final wasListening = _listening;
    setState(() {
      _state = state;
      if (_listening) _startingSession = null;
    });
    if (wasListening != _listening) widget.onListeningChanged?.call(_listening);
    // Failures to start are explained once `listen` returns (_toggle).
    if (state is SpeechInputError && state.isOwnedBy(this) && !_starting) {
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
    if (_transcribing) {
      await _service.cancel();
      return;
    }
    if (_starting) {
      // Still starting (e.g. the recogniser does not answer): give up.
      setState(() => _startingSession = null);
      await _service.cancel();
      return;
    }
    final session = ++_starts;
    setState(() => _startingSession = session);
    final started = await _service.listen(
      widget.languageCode,
      preferOnDevice: widget.preferOnDevice,
      owner: this,
    );
    // Cancelled, listening already, or another tap took over.
    if (!mounted || _startingSession != session) return;
    setState(() => _startingSession = null);
    if (started) return;
    // Read the state rather than wait for it: a failure that repeats the
    // previous one is not reported again on [SpeechInputService.states].
    // Only missing offline engines fail a start with an error (not an
    // earlier session's error, e.g. when another button took over).
    final failure = switch (_service.state) {
      SpeechInputUnavailable(:final failure?) => failure,
      SpeechInputError(
                failure: SpeechInputFailure.offlineModelMissing ||
                    SpeechInputFailure.offlineUnavailable,
              ) &&
              final error
          when error.isOwnedBy(this) =>
        error.failure,
      _ => null,
    };
    if (failure != null) _showError(failure);
  }

  void _showError(SpeechInputFailure failure) => showVoiceInputErrorSnackBar(
    context,
    failure,
    onDevice: widget.preferOnDevice ?? _service.preferOnDevice.value,
    offlineSupported: _service.isOfflineSupported,
  );

  @override
  Widget build(BuildContext context) {
    if (!_service.isPlatformSupported) return const SizedBox.shrink();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final listening = _listening;
    final transcribing = _transcribing;
    final starting = _starting && !listening && !transcribing;
    final state = _state;
    final off = state is SpeechInputUnavailable && !starting;
    final level = listening && state is SpeechInputListening
        ? state.level
        : 0.0;
    final prominent = widget.prominent;
    final size = prominent ? VoiceInputButton.prominentSize : 48.0;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (listening) ...[
            _PulseRing(size: size),
            Semantics(
              liveRegion: true,
              label: l10n.voiceInputListening,
              child: _LevelRing(level: level, size: size),
            ),
          ],
          if (transcribing)
            Semantics(
              liveRegion: true,
              label: l10n.voiceInputTranscribing,
              child: _ProgressRing(
                key: VoiceInputButton.transcribingKey,
                size: size - 4,
              ),
            ),
          if (starting)
            Semantics(
              liveRegion: true,
              label: l10n.voiceInputStarting,
              child: _ProgressRing(
                key: VoiceInputButton.startingKey,
                size: size - 4,
              ),
            ),
          IconButton(
            tooltip: listening
                ? l10n.voiceInputStop
                : transcribing
                ? l10n.voiceInputCancelTranscription
                : starting
                ? l10n.voiceInputCancelStart
                : off
                ? l10n.voiceInputUnavailable
                : l10n.voiceInputStart,
            isSelected: listening,
            iconSize: prominent ? 36 : null,
            // An accent mic; a filled accent circle while listening; a
            // dimmed crossed-out mic while voice input is unavailable (still
            // tappable: it explains why). The prominent button is always a
            // filled circle (a neutral one while unavailable).
            style: prominent
                ? IconButton.styleFrom(
                    fixedSize: Size.square(size),
                    backgroundColor: off
                        ? scheme.surfaceContainerHighest
                        : scheme.primary,
                    foregroundColor: off
                        ? scheme.onSurfaceVariant
                        : scheme.onPrimary,
                  )
                : listening
                ? IconButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  )
                : IconButton.styleFrom(
                    foregroundColor: off
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                  ),
            icon: Icon(
              off
                  ? Icons.mic_off_outlined
                  : prominent
                  ? Icons.mic
                  : Icons.mic_none_outlined,
            ),
            selectedIcon: const Icon(Icons.mic),
            onPressed: () => unawaited(_toggle()),
          ),
        ],
      ),
    );
  }
}

/// A thin progress ring around the button (starting, transcribing).
class _ProgressRing extends StatelessWidget {
  const new({required this.size, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox.square(
      dimension: size,
      child: const CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

/// Translucent accent circle behind the button, scaled by the input
/// [level] (static when animations are disabled).
class _LevelRing extends StatelessWidget {
  const new({required this.level, required this.size});

  final double level;
  final double size;

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
          child: SizedBox.square(dimension: size),
        ),
      ),
    );
  }
}

/// A subtle accent ring that keeps pulsing outwards while listening;
/// nothing when animations are disabled.
class _PulseRing extends StatefulWidget {
  const new({required this.size});

  final double size;

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
        key: VoiceInputButton.pulseRingKey,
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
          child: SizedBox.square(dimension: widget.size),
        ),
      ),
    );
  }
}
