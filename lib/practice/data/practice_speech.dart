import 'dart:async';

import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/pcm_recorder.dart';
import 'package:mozhi/voice/offline/whisper_speech_recognizer_adapter.dart';
import 'package:mozhi/voice/speech_recognizer_adapter.dart';
import 'package:whisper_speech/whisper_speech.dart' show whisperLanguageFor;

/// Whether speaking practice can run.
enum PracticeSpeechAvailability {
  /// Not on this device: no on-device speech recognition (the web app,
  /// an unsupported phone).
  unsupported,

  /// Whisper runs here, but no speech model is installed.
  modelMissing,

  /// Ready.
  ready,
}

/// Why listening failed.
enum PracticeSpeechFailure {
  /// The microphone may not be used.
  permissionDenied,

  /// No speech model is installed.
  modelMissing,

  /// Nothing was heard.
  noSpeech,

  /// The microphone failed.
  audio,

  /// The recognizer failed.
  engine,

  /// Listening was cancelled (no message).
  cancelled,
}

/// [PracticeRecognizer.listen] failed.
class PracticeSpeechException implements Exception {
  const new(this.failure);

  final PracticeSpeechFailure failure;

  @override
  String toString() => 'PracticeSpeechException(${failure.name})';
}

/// Listens to the user saying a phrase, on this device only.
abstract interface class PracticeRecognizer {
  /// Whether speaking practice can run here.
  Future<PracticeSpeechAvailability> availability();

  /// Whether it can listen in the language [code] (an app code).
  bool supportsLanguage(String code);

  /// Listens in the language [code] until [stop] (or a pause after
  /// speech, or [maxPracticeRecording]) and completes with what was heard,
  /// transcribed on this device. [onLevel] gets the loudness (0 to 1),
  /// [onTranscribing] runs when recording ended and the transcription
  /// started. Throws [PracticeSpeechException].
  Future<String> listen(
    String code, {
    void Function(double level)? onLevel,
    void Function()? onTranscribing,
  });

  /// Stops recording; [listen] completes with the transcription.
  Future<void> stop();

  /// Drops the recording; [listen] fails with
  /// [PracticeSpeechFailure.cancelled].
  Future<void> cancel();

  /// Releases the microphone.
  Future<void> dispose();
}

/// The longest recording of speaking practice.
const maxPracticeRecording = Duration(seconds: 30);

/// [PracticeRecognizer] with Whisper on this device ([OfflineSpeech],
/// through [WhisperSpeechRecognizerAdapter]): the recording stays in
/// memory, is transcribed on the device and dropped; the audio never
/// leaves it and is never stored. Unsupported without `speech` (the web
/// app, phones where Whisper cannot run).
class WhisperPracticeRecognizer implements PracticeRecognizer {
  new({
    OfflineSpeech? speech,
    PcmRecorder? recorder,
    OfflineSpeechRecognizerAdapter? adapter,
  }) : _speech = speech,
       _adapter =
           adapter ??
           (speech == null
               ? null
               : WhisperSpeechRecognizerAdapter(
                   speech: speech,
                   recorder: recorder,
                 ));

  /// The silence after speech that ends a recording on its own.
  static const pause = Duration(seconds: 2);

  final OfflineSpeech? _speech;
  final OfflineSpeechRecognizerAdapter? _adapter;
  Completer<String>? _pending;

  @override
  Future<PracticeSpeechAvailability> availability() async {
    final speech = _speech;
    final adapter = _adapter;
    if (adapter == null || (speech != null && !speech.isAvailable)) {
      return PracticeSpeechAvailability.unsupported;
    }
    try {
      return await adapter.isReady()
          ? PracticeSpeechAvailability.ready
          : PracticeSpeechAvailability.modelMissing;
    } on Object {
      return PracticeSpeechAvailability.modelMissing;
    }
  }

  @override
  bool supportsLanguage(String code) => whisperLanguageFor(code) != null;

  @override
  Future<String> listen(
    String code, {
    void Function(double level)? onLevel,
    void Function()? onTranscribing,
  }) async {
    final adapter = _adapter;
    if (adapter == null) {
      throw const PracticeSpeechException(PracticeSpeechFailure.engine);
    }
    await cancel();
    final pending = _pending = Completer<String>();
    // A failure may come before anyone waits (while initialising), or
    // after nobody does (cancelled): never an unhandled error.
    unawaited(pending.future.then<void>((_) {}, onError: (Object _) {}));
    void fail(PracticeSpeechFailure failure) {
      if (!pending.isCompleted) {
        pending.completeError(PracticeSpeechException(failure));
      }
    }

    final ready = await adapter.initialize(
      onError: (error) {
        if (identical(_pending, pending)) fail(failureOf(error.message));
      },
      onStatus: (status) {
        if (identical(_pending, pending) &&
            status == SpeechRecognizerStatus.transcribing) {
          onTranscribing?.call();
        }
      },
    );
    if (!ready) fail(PracticeSpeechFailure.engine);
    if (pending.isCompleted) return await pending.future;
    try {
      await adapter.listen(
        request: SpeechListenRequest(
          localeId: code,
          onDevice: true,
          partialResults: false,
          pauseFor: pause,
          listenFor: maxPracticeRecording,
        ),
        onResult: (text, {required isFinal}) {
          if (isFinal && !pending.isCompleted) pending.complete(text.trim());
        },
        onSoundLevel: (dbfs) =>
            onLevel?.call(((dbfs + 60) / 50).clamp(0.0, 1.0)),
      );
    } on Object {
      fail(PracticeSpeechFailure.audio);
    }
    return await pending.future;
  }

  @override
  Future<void> stop() async {
    if (_pending == null || _pending!.isCompleted) return;
    try {
      await _adapter?.stop();
    } on Object {
      // The result (or the failure) is reported either way.
    }
  }

  @override
  Future<void> cancel() async {
    final pending = _pending;
    _pending = null;
    if (pending == null || pending.isCompleted) return;
    pending.completeError(
      const PracticeSpeechException(PracticeSpeechFailure.cancelled),
    );
    try {
      await _adapter?.cancel();
    } on Object {
      // Dropped either way.
    }
  }

  @override
  Future<void> dispose() async {
    await cancel();
    if (_adapter case final WhisperSpeechRecognizerAdapter whisper) {
      await whisper.dispose();
    }
  }

  /// The failure of a recognizer error code.
  static PracticeSpeechFailure failureOf(String code) => switch (code) {
    'error_permission' => PracticeSpeechFailure.permissionDenied,
    OfflineSpeechRecognizerAdapter.modelMissingCode =>
      PracticeSpeechFailure.modelMissing,
    'error_no_match' => PracticeSpeechFailure.noSpeech,
    'error_audio_error' => PracticeSpeechFailure.audio,
    _ => PracticeSpeechFailure.engine,
  };
}
