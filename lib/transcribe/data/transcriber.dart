import 'dart:async';
import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/pcm_recorder.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:mozhi/voice/offline/speech_frames.dart';
import 'package:mozhi/voice/offline/utterance_segmenter.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/speech_input_state.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// What a [Transcriber] reports while it listens to one recording.
sealed class TranscriberEvent extends Equatable {
  const new();

  @override
  List<Object?> get props => [];
}

/// The microphone is open.
final class TranscriberListening extends TranscriberEvent {
  const new();
}

/// The input loudness, `0..1`, and whether speech was heard so far.
final class TranscriberLevel extends TranscriberEvent {
  const new(this.level, {this.heardSpeech = false});

  final double level;
  final bool heardSpeech;

  @override
  List<Object?> get props => [level, heardSpeech];
}

/// One phrase of the recording ([TranscribedPhrase.start] and `end` count
/// from the start of the recording), and how many wait for the engine.
final class TranscriberHeard extends TranscriberEvent {
  const new(this.phrase, {this.pending = 0});

  final TranscribedPhrase phrase;
  final int pending;

  @override
  List<Object?> get props => [phrase, pending];
}

/// A phrase is over and waits for the engine ([pending] in all).
final class TranscriberPending extends TranscriberEvent {
  const new(this.pending);

  final int pending;

  @override
  List<Object?> get props => [pending];
}

/// The words heard so far of the phrase in progress (recognisers that
/// recognise while listening).
final class TranscriberPartial extends TranscriberEvent {
  const new(this.text);

  final String text;

  @override
  List<Object?> get props => [text];
}

/// Listening failed or could not start ([failure]); the recording is over.
final class TranscriberFailed extends TranscriberEvent {
  const new(this.failure);

  final SpeechInputFailure failure;

  @override
  List<Object?> get props => [failure];
}

/// Listens for a long time (a lecture, a tour, a meeting) and writes down
/// every phrase: [listen] opens the microphone, and the returned stream
/// reports phrase after phrase until [stop] (the last phrases still
/// arrive, then it closes) or [cancel] (it closes at once). Listening
/// again cancels the previous recording.
abstract interface class Transcriber {
  /// Whether speech stays on this device.
  bool get onDevice;

  /// Listens in [language] (an app code; null or `auto` detects it).
  Stream<TranscriberEvent> listen({String? language});

  /// Ends the recording; the phrases still being transcribed follow.
  Future<void> stop();

  /// Drops the recording.
  Future<void> cancel();
}

/// Maps a loudness in dBFS to `0..1` (-60 dBFS and below is 0, -10 and
/// above 1).
double normalizedLevel(double dbfs) => ((dbfs + 60) / 50).clamp(0.0, 1.0);

/// [Transcriber] with on-device Whisper ([OfflineSpeech]): the microphone
/// ([PcmRecorder], 16 kHz PCM) is cut into phrases at pauses (Silero VAD
/// when its model is installed, else loudness, with a longer pause) and
/// each phrase is transcribed on this device as soon as it is over
/// ([PhraseTranscriber]). Nothing leaves the device.
class WhisperTranscriber implements Transcriber {
  new({required this._speech, PcmRecorder? recorder})
    : _recorder = recorder ?? RecordPcmRecorder();

  /// The pause that ends a phrase with the voice activity model.
  static const vadPause = Duration(milliseconds: 500);

  /// The pause that ends a phrase by loudness (more easily fooled).
  static const loudnessPause = Duration(milliseconds: 700);

  final OfflineSpeech _speech;
  final PcmRecorder _recorder;
  _Recording? _current;

  @override
  bool get onDevice => true;

  @override
  Stream<TranscriberEvent> listen({String? language}) {
    final previous = _current;
    if (previous != null) unawaited(_cancel(previous));
    final recording = _current = _Recording();
    unawaited(_start(recording, language));
    return recording.events.stream;
  }

  Future<void> _start(_Recording recording, String? language) async {
    try {
      if (!await _speech.isReady()) {
        return await _fail(recording, SpeechInputFailure.offlineModelMissing);
      }
      if (!await _recorder.hasPermission()) {
        return await _fail(recording, SpeechInputFailure.permissionDenied);
      }
      final vad = await _speech.isVadReady();
      final classifier = vad
          ? SileroSpeechClassifier(_speech)
          : LoudnessSpeechClassifier();
      if (vad) {
        try {
          await classifier.reset();
        } on Object {
          // Loudness takes over if the detector fails.
        }
      }
      if (recording.closed) return;
      final phrases = recording.phrases = PhraseTranscriber(
        transcribe: _speech.transcribe,
        classifier: classifier,
        fallback: vad ? LoudnessSpeechClassifier() : null,
        segmenter: UtteranceSegmenter(pause: vad ? vadPause : loudnessPause),
        language: whisperLanguageFor(language),
        cancelEngine: _speech.cancel,
        onPhrase: (phrase) => recording.add(
          TranscriberHeard(phrase, pending: recording.phrases?.pending ?? 0),
        ),
        onActivity: () => _onActivity(recording),
      );
      final stream = await _recorder.start();
      if (recording.closed) {
        await _stopRecorder();
        return;
      }
      recording.subscription = stream.listen(
        (chunk) {
          if (recording.closed || recording.stopping) return;
          phrases.add(chunk);
          recording.add(
            TranscriberLevel(
              normalizedLevel(phrases.level),
              heardSpeech: phrases.heardSpeech,
            ),
          );
        },
        onError: (Object _) =>
            unawaited(_fail(recording, SpeechInputFailure.audio)),
        onDone: () => unawaited(_finish(recording)),
      );
      recording.add(const TranscriberListening());
    } on Object {
      await _fail(recording, SpeechInputFailure.audio);
    }
  }

  /// Reports phrases that wait for the engine.
  void _onActivity(_Recording recording) {
    final pending = recording.phrases?.pending ?? 0;
    if (pending != recording.reportedPending) {
      recording.reportedPending = pending;
      if (pending > 0) recording.add(TranscriberPending(pending));
    }
  }

  @override
  Future<void> stop() async {
    final recording = _current;
    if (recording == null) return;
    await _finish(recording);
  }

  @override
  Future<void> cancel() async {
    final recording = _current;
    if (recording == null) return;
    await _cancel(recording);
  }

  Future<void> _finish(_Recording recording) async {
    if (recording.closed || recording.stopping) return;
    recording.stopping = true;
    await recording.subscription?.cancel();
    await _stopRecorder();
    await recording.phrases?.finish();
    if (identical(_current, recording)) _current = null;
    await recording.close();
  }

  Future<void> _cancel(_Recording recording) async {
    if (identical(_current, recording)) _current = null;
    if (recording.closed) return;
    final subscription = recording.subscription;
    await recording.close();
    await subscription?.cancel();
    await recording.phrases?.cancel();
    await _stopRecorder();
  }

  Future<void> _fail(_Recording recording, SpeechInputFailure failure) async {
    if (recording.closed) return;
    recording.add(TranscriberFailed(failure));
    await _cancel(recording);
  }

  Future<void> _stopRecorder() async {
    try {
      await _recorder.stop();
    } on Object {
      // The microphone is released either way.
    }
  }

  /// Releases the microphone for good.
  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}

/// [Transcriber] over the system's speech recognition
/// ([SpeechInputService]) where it recognises continuously (the
/// browser's): each utterance it ends after a pause is a phrase, and it
/// listens again right away. Where the recogniser sends the audio is the
/// recogniser's business (the browser's maker, usually); it is not used in
/// Offline only (the service refuses).
class SystemTranscriber implements Transcriber {
  new(this._service, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SpeechInputService _service;
  final DateTime Function() _clock;
  _Utterances? _current;

  @override
  bool get onDevice => false;

  @override
  Stream<TranscriberEvent> listen({String? language}) {
    final previous = _current;
    if (previous != null) unawaited(_close(previous, cancel: true));
    final session = _current = _Utterances(language, _clock());
    session
      ..states = _service.states.listen((state) => _onState(session, state))
      ..results = _service.results.listen(
        (result) => _onResult(session, result),
      );
    unawaited(_next(session));
    return session.events.stream;
  }

  Future<void> _next(_Utterances session) async {
    if (session.closed || session.stopping) return;
    final owner = Object();
    session
      ..owner = owner
      ..utteranceStart = _clock();
    final started = await _service.listen(session.language, owner: owner);
    if (session.closed || !identical(session.owner, owner)) return;
    if (started) {
      if (!session.announced) {
        session
          ..announced = true
          ..add(const TranscriberListening());
      }
      return;
    }
    final failure = switch (_service.state) {
      SpeechInputUnavailable(:final failure) =>
        failure ?? SpeechInputFailure.recognizerUnavailable,
      final SpeechInputError error when error.isOwnedBy(owner) => error.failure,
      _ => SpeechInputFailure.unknown,
    };
    session.add(TranscriberFailed(failure));
    await _close(session, cancel: false);
  }

  void _onState(_Utterances session, SpeechInputState state) {
    if (session.closed) return;
    final owner = session.owner;
    switch (state) {
      case SpeechInputListening() when state.isOwnedBy(owner):
        session.add(
          TranscriberLevel(state.level, heardSpeech: state.heardSpeech),
        );
      case SpeechInputError(failure: SpeechInputFailure.noMatch)
          when state.isOwnedBy(owner):
        // Silence: listen again.
        unawaited(_restart(session));
      case SpeechInputError() when state.isOwnedBy(owner):
        session.add(TranscriberFailed(state.failure));
        unawaited(_close(session, cancel: false));
      case SpeechInputIdle():
        // The utterance ended; its final result (if any) comes first or
        // within a moment. Then the next one.
        if (owner != null) unawaited(_restart(session));
      case _:
        break;
    }
  }

  void _onResult(_Utterances session, SpeechInputResult result) {
    if (session.closed || !identical(result.owner, session.owner)) return;
    final text = result.text.trim();
    if (!result.isFinal) {
      session.add(TranscriberPartial(text));
      return;
    }
    if (text.isNotEmpty) {
      session.add(
        TranscriberHeard(
          TranscribedPhrase(
            index: session.index++,
            start: session.utteranceStart.difference(session.started),
            end: _clock().difference(session.started),
            status: PhraseStatus.transcribed,
            text: text,
            language: result.language,
          ),
        ),
      );
    }
    unawaited(_restart(session));
  }

  /// Listens for the next utterance (once per utterance), unless stopped.
  Future<void> _restart(_Utterances session) async {
    final owner = session.owner;
    if (owner == null || session.closed) return;
    // Give a final result that follows the end of listening its moment.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!identical(session.owner, owner) || session.closed) return;
    session.owner = null;
    if (session.stopping) {
      await _close(session, cancel: false);
    } else {
      await _next(session);
    }
  }

  @override
  Future<void> stop() async {
    final session = _current;
    if (session == null || session.closed) return;
    session.stopping = true;
    if (session.owner == null) {
      await _close(session, cancel: false);
      return;
    }
    await _service.stop();
    // The final result arrives, then the session closes (see _restart);
    // a recogniser that never sends it is given up on.
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 3),
        () => _close(session, cancel: true),
      ),
    );
  }

  @override
  Future<void> cancel() async {
    final session = _current;
    if (session == null) return;
    await _close(session, cancel: true);
  }

  Future<void> _close(_Utterances session, {required bool cancel}) async {
    if (identical(_current, session)) _current = null;
    if (session.closed) return;
    final listening =
        session.owner != null && _service.state.isOwnedBy(session.owner);
    session.owner = null;
    await session.close();
    if (cancel && listening) await _service.cancel();
  }
}

/// One recording of [WhisperTranscriber].
final class _Recording {
  final events = StreamController<TranscriberEvent>();

  /// The microphone stream.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? subscription;
  PhraseTranscriber? phrases;
  bool stopping = false;
  bool closed = false;
  int reportedPending = 0;

  void add(TranscriberEvent event) {
    if (!closed) events.add(event);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    // Not awaited: it completes once a listener has seen the end.
    unawaited(events.close());
  }
}

/// The utterances of one [SystemTranscriber] recording.
final class _Utterances {
  new(this.language, this.started);

  final String? language;
  final DateTime started;
  final events = StreamController<TranscriberEvent>();
  StreamSubscription<SpeechInputState>? states;
  StreamSubscription<SpeechInputResult>? results;

  /// The owner of the utterance being listened to; null between them.
  Object? owner;
  DateTime utteranceStart = DateTime.fromMillisecondsSinceEpoch(0);
  int index = 0;
  bool announced = false;
  bool stopping = false;
  bool closed = false;

  void add(TranscriberEvent event) {
    if (!closed) events.add(event);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(events.close());
    await states?.cancel();
    await results?.cancel();
  }
}

/// A phrase's start formatted as `m:ss` (`h:mm:ss` from an hour on).
String formatTranscriptTime(Duration time) {
  final seconds = math.max(0, time.inSeconds);
  final h = seconds ~/ 3600;
  final m = (seconds ~/ 60) % 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
