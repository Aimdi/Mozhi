import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/recognizer/conversation_recognizer.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:translation_repository/translation_repository.dart';

/// Creates the recogniser of a hands-free conversation; null when there is
/// none (no hands-free conversation).
typedef ConversationRecognizerBuilder = ConversationRecognizer? Function(
  BuildContext context,
);

/// The default [ConversationRecognizerBuilder]: a
/// [SpeechInputConversationRecognizer] over the app-wide
/// [SpeechInputService] (`RepositoryProvider<SpeechInputService>`) where it
/// can recognise speech; null without one.
ConversationRecognizer? speechInputConversationRecognizer(
  BuildContext context,
) {
  try {
    final service = context.read<SpeechInputService>();
    return service.isPlatformSupported
        ? SpeechInputConversationRecognizer(service)
        : null;
  } on ProviderNotFoundException {
    return null;
  }
}

/// [ConversationRecognizer] over the app-wide [SpeechInputService]: each
/// utterance is a session of the service with its own owner token, so it
/// only reacts to its own states and results. The recogniser the service
/// picks (system or on-device Whisper, see [SpeechInputService]) decides
/// whether the language can be detected
/// ([SpeechInputListening.detectsLanguage]).
///
/// Failures to start are read from [SpeechInputService.state] like
/// `VoiceInputButton` does (the service does not repeat an unchanged state); a
/// session that does not start without a failure (another one took over) ends
/// as `interrupted`. When the microphone closes without a result the utterance
/// waits [finalResultGrace] for it (Android reports the end of listening before
/// the final result); a session that ends without a result is reported as
/// [ConversationHeardEnd], `interrupted` when another owner took the microphone
/// over. [ConversationHeardSpeech] follows [SpeechInputListening.heardSpeech]
/// (words, or the voice activity detection of an on-device recogniser), not the
/// loudness.
///
/// `timer` creates the grace timers (default [Timer.new]); tests pass fake
/// ones.
class SpeechInputConversationRecognizer implements ConversationRecognizer {
  new(this._service, {Timer Function(Duration, void Function())? timer})
    : _timer = timer ?? Timer.new;

  /// How long an utterance whose microphone closed waits for its final
  /// result: a little longer than `speech_to_text`'s final timeout (2 s),
  /// after which it delivers the last words as the final result.
  static const finalResultGrace = Duration(milliseconds: 2500);

  final SpeechInputService _service;
  final Timer Function(Duration duration, void Function() callback) _timer;
  _Utterance? _current;
  bool _disposed = false;

  @override
  Stream<ConversationHearing> listen(
    Language language, {
    bool detectLanguage = false,
    Duration? pause,
  }) {
    final previous = _current;
    if (previous != null) unawaited(previous.close());
    final utterance = _current = _Utterance();
    if (_disposed) {
      unawaited(utterance.close());
      return utterance.events.stream;
    }
    utterance
      ..states = _service.states.listen((state) => _onState(utterance, state))
      ..results = _service.results.listen(
        (result) => _onResult(utterance, result),
      );
    unawaited(_start(utterance, language.code, detectLanguage, pause));
    return utterance.events.stream;
  }

  Future<void> _start(
    _Utterance utterance,
    String languageCode,
    bool detectLanguage,
    Duration? pause,
  ) async {
    final bool started;
    try {
      started = await _service.listen(
        languageCode,
        owner: utterance,
        detectLanguage: detectLanguage,
        pause: pause,
      );
    } on Object {
      _finish(
        utterance,
        const ConversationHeardFailure(SpeechInputFailure.unknown),
      );
      return;
    }
    utterance.starting = false;
    if (started || utterance.closed) return;
    final failure = switch (_service.state) {
      SpeechInputUnavailable(:final failure) =>
        failure ?? SpeechInputFailure.recognizerUnavailable,
      final SpeechInputError error when error.isOwnedBy(utterance) =>
        error.failure,
      _ => null,
    };
    // Not started without a failure of its own: another session took the
    // microphone over (or is taking it), which pauses the conversation
    // instead of passing for silence.
    _finish(
      utterance,
      failure == null
          ? const ConversationHeardEnd(interrupted: true)
          : _failure(failure),
    );
  }

  ConversationHeardFailure _failure(SpeechInputFailure failure) =>
      ConversationHeardFailure(
        failure,
        onDevice: _service.preferOnDevice.value,
        offlineSupported: _service.isOfflineSupported,
      );

  void _onState(_Utterance utterance, SpeechInputState state) {
    if (utterance.closed) return;
    switch (state) {
      case SpeechInputListening() when state.isOwnedBy(utterance):
        if (!utterance.active) {
          utterance
            ..active = true
            ..add(
              ConversationHeardStart(detectsLanguage: state.detectsLanguage),
            );
        }
        if (state.level != utterance.level) {
          utterance
            ..level = state.level
            ..add(ConversationHeardLevel(state.level));
        }
        if (state.heardSpeech && !utterance.heardSpeech) {
          utterance
            ..heardSpeech = true
            ..add(const ConversationHeardSpeech());
        }
      case SpeechInputTranscribing() when state.isOwnedBy(utterance):
        utterance
          ..active = true
          ..add(const ConversationHeardTranscribing());
      case SpeechInputError() when state.isOwnedBy(utterance):
        _finish(utterance, _failure(state.failure));
      case SpeechInputListening() || SpeechInputTranscribing():
        // Another owner took the microphone over.
        if (utterance.active) {
          _finish(utterance, const ConversationHeardEnd(interrupted: true));
        }
      case SpeechInputUnavailable(:final failure):
        if (utterance.active) {
          _finish(
            utterance,
            _failure(failure ?? SpeechInputFailure.recognizerUnavailable),
          );
        }
      case SpeechInputIdle():
        // The microphone closed. The final result may still follow:
        // Android reports `notListening` before it.
        if (utterance.active) _awaitFinalResult(utterance);
      case SpeechInputError():
        // Someone else's session failed: ours is over.
        if (utterance.active) _finish(utterance, const ConversationHeardEnd());
    }
  }

  /// Waits [finalResultGrace] for [utterance]'s final result (or error);
  /// without one it ended without a result.
  void _awaitFinalResult(_Utterance utterance) {
    utterance.grace ??= _timer(
      finalResultGrace,
      () => _finish(utterance, const ConversationHeardEnd()),
    );
  }

  void _onResult(_Utterance utterance, SpeechInputResult result) {
    if (utterance.closed || !identical(result.owner, utterance)) return;
    if (result.isFinal) {
      _finish(
        utterance,
        ConversationHeardFinal(result.text, language: result.language),
      );
    } else {
      utterance.add(ConversationHeardPartial(result.text));
    }
  }

  void _finish(_Utterance utterance, ConversationHearing last) {
    if (utterance.closed) return;
    utterance.add(last);
    if (identical(_current, utterance)) _current = null;
    unawaited(utterance.close());
  }

  @override
  Future<void> cancel() async {
    final utterance = _current;
    _current = null;
    if (utterance == null || utterance.closed) return;
    // Only this utterance's session (or its start) is cancelled.
    final ours = utterance.starting || _service.state.isOwnedBy(utterance);
    await utterance.close();
    if (ours) await _service.cancel();
  }

  @override
  Future<void> dispose() async {
    await cancel();
    _disposed = true;
  }
}

/// One utterance: its events and its subscriptions to the service.
final class _Utterance {
  final events = StreamController<ConversationHearing>();
  StreamSubscription<SpeechInputState>? states;
  StreamSubscription<SpeechInputResult>? results;

  /// [SpeechInputService.listen] has not returned yet.
  bool starting = true;

  /// The service reported this utterance's session (listening or
  /// transcribing).
  bool active = false;
  bool closed = false;
  double level = 0;

  /// [ConversationHeardSpeech] was reported.
  bool heardSpeech = false;

  /// Runs while the closed microphone's final result is awaited.
  Timer? grace;

  void add(ConversationHearing event) {
    if (!closed) events.add(event);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    grace?.cancel();
    // Not awaited: it only completes once a listener has seen the end.
    unawaited(events.close());
    await states?.cancel();
    await results?.cancel();
  }
}
