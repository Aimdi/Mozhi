import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/pcm_recorder.dart';
import 'package:mozhi/voice/offline/voice_activity.dart';
import 'package:mozhi/voice/speech_recognizer_adapter.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// [SpeechRecognizerAdapter] for offline voice input with Whisper
/// ([OfflineSpeech]): the audio is recorded with [PcmRecorder] (16 kHz mono
/// PCM16) and transcribed on this device after recording, so nothing
/// leaves it.
///
/// * [initialize] succeeds when a model is installed and Whisper runs here
///   (else it reports [OfflineSpeechRecognizerAdapter.modelMissingCode])
///   and the microphone may be used (it asks once; `error_permission`
///   otherwise).
/// * [locales] are Whisper's 99 languages (Whisper codes, which
///   `SpeechLocaleMatcher` maps app codes onto: `jv` -> `jw`, `fil` ->
///   `tl`, ...); no locale id means Whisper detects the language.
/// * [listen] records until [stop], until [SpeechListenRequest.pauseFor]
///   of silence after speech ([VoiceActivityDetector]) or until
///   [maxDuration] (Whisper's 30 s window; at most
///   [SpeechListenRequest.listenFor]), reporting the loudness of every
///   chunk (dBFS) as the sound level. Then it reports
///   [SpeechRecognizerStatus.transcribing], transcribes and delivers one
///   final result, followed by [SpeechRecognizerStatus.done]. A recording
///   without speech is not transcribed: it fails with `error_no_match`,
///   like an empty transcription.
/// * [cancel] drops the recording or stops the transcription.
class WhisperSpeechRecognizerAdapter implements OfflineSpeechRecognizerAdapter {
  new({
    required this._speech,
    PcmRecorder? recorder,
    this.maxDuration = whisperWindow,
  }) : _recorder = recorder ?? RecordPcmRecorder();

  final OfflineSpeech _speech;
  final PcmRecorder _recorder;

  /// The longest recording (Whisper reads 30 s at a time).
  final Duration maxDuration;

  void Function(SpeechRecognizerError error)? _onError;
  void Function(SpeechRecognizerStatus status)? _onStatus;
  _Session? _session;

  @override
  Future<bool> isReady() async {
    try {
      return await _speech.isReady();
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> initialize({
    required void Function(SpeechRecognizerError error) onError,
    required void Function(SpeechRecognizerStatus status) onStatus,
  }) async {
    _onError = onError;
    _onStatus = onStatus;
    if (!await isReady()) {
      onError(
        const SpeechRecognizerError(
          OfflineSpeechRecognizerAdapter.modelMissingCode,
          permanent: true,
        ),
      );
      return false;
    }
    if (!await _recorder.hasPermission()) {
      onError(const SpeechRecognizerError('error_permission', permanent: true));
      return false;
    }
    return true;
  }

  @override
  Future<bool> hasPermission() => _recorder.hasPermission(request: false);

  @override
  Future<List<SpeechRecognizerLocale>> locales() async => [
    for (final MapEntry(key: code, value: name) in whisperLanguages.entries)
      SpeechRecognizerLocale(code, name),
  ];

  /// Whisper detects the language when none is given.
  @override
  Future<String?> systemLocaleId() async => null;

  @override
  Future<void> listen({
    required SpeechListenRequest request,
    required SpeechRecognizerResultListener onResult,
    required void Function(double level) onSoundLevel,
  }) async {
    await cancel();
    final limit = request.listenFor < maxDuration
        ? request.listenFor
        : maxDuration;
    final session = _Session(
      language: whisperLanguageFor(request.localeId),
      onResult: onResult,
      onSoundLevel: onSoundLevel,
      buffer: Pcm16Buffer(
        maxSamples: math.max(
          1,
          limit.inMilliseconds * whisperSampleRate ~/ 1000,
        ),
      ),
      voice: VoiceActivityDetector(pause: request.pauseFor),
    );
    _session = session;
    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.start();
    } on Object {
      if (identical(_session, session)) _session = null;
      _error('error_audio_error');
      return;
    }
    if (!identical(_session, session)) {
      // Cancelled while the microphone opened.
      await _stopRecorder();
      return;
    }
    session.subscription = stream.listen(
      (chunk) => _onChunk(session, chunk),
      onError: (Object _) => unawaited(_fail(session, 'error_audio_error')),
      onDone: () => unawaited(_finish(session)),
    );
    _onStatus?.call(SpeechRecognizerStatus.listening);
  }

  @override
  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    await _finish(session);
  }

  @override
  Future<void> cancel() async {
    final session = _session;
    _session = null;
    if (session == null) return;
    if (session.recording) {
      session.recording = false;
      // Without a subscription the microphone is still opening: listen()
      // releases it once it is open.
      if (session.subscription case final subscription?) {
        await subscription.cancel();
        await _stopRecorder();
      }
    } else {
      try {
        await _speech.cancel();
      } on Object {
        // The transcription is dropped either way.
      }
    }
  }

  /// Releases the microphone (app shutdown).
  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }

  void _onChunk(_Session session, Uint8List chunk) {
    if (!identical(_session, session) || !session.recording) return;
    final added = session.buffer.add(chunk);
    final level = session.buffer.lastLevel;
    session.voice.add(level, added);
    session.onSoundLevel(level);
    if (session.buffer.isFull || session.voice.pausedAfterSpeech) {
      unawaited(_finish(session));
    }
  }

  /// Stops recording and transcribes what was recorded.
  Future<void> _finish(_Session session) async {
    if (!identical(_session, session) || !session.recording) return;
    session.recording = false;
    await session.subscription?.cancel();
    await _stopRecorder();
    if (!identical(_session, session)) return;
    _onStatus?.call(SpeechRecognizerStatus.transcribing);
    unawaited(_transcribe(session));
  }

  Future<void> _transcribe(_Session session) async {
    String? failure;
    var text = '';
    if (!session.voice.heardSpeech) {
      failure = 'error_no_match';
    } else {
      try {
        final result = await _speech.transcribe(
          session.buffer.toFloat32List(),
          language: session.language,
        );
        text = result.text;
        if (text.isEmpty) failure = 'error_no_match';
      } on WhisperCancelledException {
        return;
      } on WhisperModelMissingException {
        failure = OfflineSpeechRecognizerAdapter.modelMissingCode;
      } on Object {
        failure = OfflineSpeechRecognizerAdapter.engineErrorCode;
      }
    }
    if (!identical(_session, session)) return;
    _session = null;
    if (failure != null) {
      _error(failure);
    } else {
      session.onResult(text, isFinal: true);
    }
    _onStatus?.call(SpeechRecognizerStatus.done);
  }

  Future<void> _fail(_Session session, String code) async {
    if (!identical(_session, session)) return;
    _session = null;
    session.recording = false;
    await session.subscription?.cancel();
    await _stopRecorder();
    _error(code);
  }

  void _error(String code) => _onError?.call(
    SpeechRecognizerError(
      code,
      permanent:
          code != 'error_no_match' &&
          code != OfflineSpeechRecognizerAdapter.engineErrorCode,
    ),
  );

  Future<void> _stopRecorder() async {
    try {
      await _recorder.stop();
    } on Object {
      // The microphone is released either way.
    }
  }
}

/// One recording and its transcription.
final class _Session {
  new({
    required this.language,
    required this.onResult,
    required this.onSoundLevel,
    required this.buffer,
    required this.voice,
  });

  /// Whisper code, or null to detect it.
  final String? language;
  final SpeechRecognizerResultListener onResult;
  final void Function(double level) onSoundLevel;
  final Pcm16Buffer buffer;
  final VoiceActivityDetector voice;

  /// The microphone stream; the adapter cancels it when the recording ends
  /// (`_finish`, `_fail`, `cancel`).
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? subscription;
  bool recording = true;
}
