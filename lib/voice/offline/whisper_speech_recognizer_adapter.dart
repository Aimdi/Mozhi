import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/pcm_recorder.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:mozhi/voice/offline/speech_frames.dart';
import 'package:mozhi/voice/offline/utterance_segmenter.dart';
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
///   chunk (dBFS) as the sound level and whether the detector heard
///   speech yet as [heardSpeech]. Then it reports
///   [SpeechRecognizerStatus.transcribing], transcribes and delivers one
///   final result, followed by [SpeechRecognizerStatus.done]. A recording
///   without speech is not transcribed: it fails with `error_no_match`,
///   like an empty transcription.
/// * With the voice activity model installed ([OfflineSpeech.isVadReady])
///   the recording is cut into phrases at pauses of [phrasePause]
///   (Silero VAD tells speech from noise; [PhraseTranscriber]) and each
///   phrase is transcribed as soon as it is over: the text so far arrives
///   as partial results while the user speaks, the final result is all of
///   it (sooner: only the last phrase is left to transcribe after the
///   pause), and a session may last [SpeechListenRequest.listenFor], as
///   no phrase exceeds Whisper's window. Without it, loudness
///   ([VoiceActivityDetector]) ends the recording and it is transcribed
///   in one pass, as described above.
/// * [detectedLanguage] is the language Whisper transcribed the final
///   result in (the detected one when no locale id was given; with
///   phrases, the language of most of the speech).
/// * [cancel] drops the recording or stops the transcription.
class WhisperSpeechRecognizerAdapter
    implements
        OfflineSpeechRecognizerAdapter,
        LanguageDetectingSpeechRecognizer,
        VoiceActivitySpeechRecognizer {
  new({
    required this._speech,
    PcmRecorder? recorder,
    this.maxDuration = whisperWindow,
    this.phrasePause = const Duration(milliseconds: 400),
  }) : _recorder = recorder ?? RecordPcmRecorder();

  final OfflineSpeech _speech;
  final PcmRecorder _recorder;

  /// The longest recording transcribed in one pass (Whisper reads 30 s at
  /// a time), without the voice activity model.
  final Duration maxDuration;

  /// The pause that ends a phrase (with the voice activity model).
  final Duration phrasePause;

  void Function(SpeechRecognizerError error)? _onError;
  void Function(SpeechRecognizerStatus status)? _onStatus;
  _Session? _session;
  String? _detectedLanguage;

  /// Bumped by [cancel]: a [listen] still checking for the voice activity
  /// model gives up.
  int _generation = 0;

  @override
  String? get detectedLanguage => _detectedLanguage;

  @override
  bool get heardSpeech => _session?.heardSpeech ?? false;

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
    final generation = _generation;
    final language = whisperLanguageFor(request.localeId);
    final phrases = await _isVadReady();
    if (generation != _generation) return;
    final classifier = phrases ? SileroSpeechClassifier(_speech) : null;
    if (classifier != null) {
      try {
        await classifier.reset();
      } on Object {
        // Loudness takes over if the detector fails.
      }
      if (generation != _generation) return;
    }
    final limit = phrases || request.listenFor < maxDuration
        ? request.listenFor
        : maxDuration;
    final session = _Session(
      language: language,
      onResult: onResult,
      onSoundLevel: onSoundLevel,
      pause: request.pauseFor,
      limit: limit,
      buffer: phrases
          ? null
          : Pcm16Buffer(
              maxSamples: math.max(
                1,
                limit.inMilliseconds * whisperSampleRate ~/ 1000,
              ),
            ),
      voice: phrases ? null : VoiceActivityDetector(pause: request.pauseFor),
    );
    if (classifier != null) {
      session.phrases = PhraseTranscriber(
        transcribe: _speech.transcribe,
        classifier: classifier,
        fallback: LoudnessSpeechClassifier(),
        segmenter: UtteranceSegmenter(pause: phrasePause),
        language: language,
        cancelEngine: _speech.cancel,
        onPhrase: (_) => _onPhrase(session),
        onActivity: () => _onActivity(session),
      );
    }
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
    _generation++;
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
    } else if (session.phrases == null) {
      try {
        await _speech.cancel();
      } on Object {
        // The transcription is dropped either way.
      }
    }
    // Stops the phrase being transcribed, while recording too.
    await session.phrases?.cancel();
  }

  /// Releases the microphone (app shutdown).
  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }

  void _onChunk(_Session session, Uint8List chunk) {
    if (!identical(_session, session) || !session.recording) return;
    if (session.phrases case final phrases?) {
      phrases.add(chunk);
      session.onSoundLevel(phrases.level);
      return;
    }
    final buffer = session.buffer!;
    final voice = session.voice!;
    final added = buffer.add(chunk);
    final level = buffer.lastLevel;
    voice.add(level, added);
    session.onSoundLevel(level);
    if (buffer.isFull || voice.pausedAfterSpeech) {
      unawaited(_finish(session));
    }
  }

  /// A chunk was classified: the recording ends after the pause (or at
  /// its limit).
  void _onActivity(_Session session) {
    final phrases = session.phrases;
    if (phrases == null || !identical(_session, session)) return;
    if ((phrases.heardSpeech && phrases.silenceAfterSpeech >= session.pause) ||
        phrases.recorded >= session.limit) {
      unawaited(_finish(session));
    }
  }

  /// A phrase was transcribed: the text so far is a partial result (but
  /// for the last one after recording: the final result follows at once).
  void _onPhrase(_Session session) {
    final phrases = session.phrases;
    if (phrases == null || !identical(_session, session)) return;
    if (!session.recording && phrases.pending == 0) return;
    final text = phrases.text;
    if (text.isEmpty || text == session.partial) return;
    session.partial = text;
    session.onResult(text, isFinal: false);
  }

  Future<bool> _isVadReady() async {
    try {
      return await _speech.isVadReady();
    } on Object {
      return false;
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
    String? language;
    var text = '';
    if (session.phrases case final phrases?) {
      final heard = await phrases.finish();
      text = phrases.text;
      language = phrases.heardLanguage;
      if (text.isEmpty) {
        failure = heard.any((phrase) => phrase.status == PhraseStatus.failed)
            ? OfflineSpeechRecognizerAdapter.engineErrorCode
            : 'error_no_match';
      }
    } else if (!session.voice!.heardSpeech) {
      failure = 'error_no_match';
    } else {
      try {
        final result = await _speech.transcribe(
          session.buffer!.toFloat32List(),
          language: session.language,
        );
        text = result.text;
        language = languageForWhisper(result.language);
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
      _detectedLanguage = language;
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

/// One recording and its transcription: in one pass ([buffer] and
/// [voice]) or phrase by phrase ([phrases]).
final class _Session {
  new({
    required this.language,
    required this.onResult,
    required this.onSoundLevel,
    required this.pause,
    required this.limit,
    this.buffer,
    this.voice,
  });

  /// Whisper code, or null to detect it.
  final String? language;
  final SpeechRecognizerResultListener onResult;
  final void Function(double level) onSoundLevel;

  /// Silence after speech that ends the recording.
  final Duration pause;

  /// The longest recording.
  final Duration limit;
  final Pcm16Buffer? buffer;
  final VoiceActivityDetector? voice;
  PhraseTranscriber? phrases;

  /// The last partial result.
  String partial = '';

  bool get heardSpeech => phrases?.heardSpeech ?? voice?.heardSpeech ?? false;

  /// The microphone stream; the adapter cancels it when the recording ends
  /// (`_finish`, `_fail`, `cancel`).
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? subscription;
  bool recording = true;
}
