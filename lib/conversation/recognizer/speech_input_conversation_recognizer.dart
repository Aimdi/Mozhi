import 'dart:async';

import 'package:mozhi/conversation/recognizer/conversation_recognizer.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:translation_repository/translation_repository.dart';

/// [ConversationRecognizer] over the app-wide [SpeechInputService]: each
/// utterance is a session of the service with its own owner token, so it
/// only reacts to its own states and results. The recogniser the service
/// picks (system or on-device Whisper, see [SpeechInputService]) decides
/// whether the language can be detected
/// ([SpeechInputListening.detectsLanguage]).
///
/// Failures to start are read from [SpeechInputService.state] like
/// `VoiceInputButton` does (the service does not repeat an unchanged
/// state). A session that ends without a result is reported as
/// [ConversationHeardEnd], `interrupted` when another owner took the
/// microphone over.
class SpeechInputConversationRecognizer implements ConversationRecognizer {
  new(this._service);

  final SpeechInputService _service;
  _Utterance? _current;
  bool _disposed = false;

  @override
  Stream<ConversationHearing> listen(
    Language language, {
    bool detectLanguage = false,
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
    unawaited(_start(utterance, language.code, detectLanguage));
    return utterance.events.stream;
  }

  Future<void> _start(
    _Utterance utterance,
    String languageCode,
    bool detectLanguage,
  ) async {
    final bool started;
    try {
      started = await _service.listen(
        languageCode,
        owner: utterance,
        detectLanguage: detectLanguage,
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
    _finish(
      utterance,
      failure == null ? const ConversationHeardEnd() : _failure(failure),
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
      case SpeechInputIdle() || SpeechInputError():
        // Ended without a final result (results arrive before the state).
        if (utterance.active) _finish(utterance, const ConversationHeardEnd());
    }
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

  void add(ConversationHearing event) {
    if (!closed) events.add(event);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    // Not awaited: it only completes once a listener has seen the end.
    unawaited(events.close());
    await states?.cancel();
    await results?.cancel();
  }
}
