import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:mozhi/voice/offline/speech_frames.dart';
import 'package:mozhi/voice/offline/utterance_segmenter.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Transcribes 16 kHz mono [samples] in [language] (a Whisper code; null
/// detects it), e.g. `OfflineSpeech.transcribe`.
typedef PhraseTranscribe = Future<WhisperTranscription> Function(
  Float32List samples, {
  String? language,
});

/// What became of a phrase of a [PhraseTranscriber].
enum PhraseStatus {
  /// Transcribed ([TranscribedPhrase.text] may still be empty: nothing
  /// was recognised).
  transcribed,

  /// Not transcribed: transcription had fallen too far behind
  /// ([PhraseTranscriber.maxBacklog]); the audio was dropped.
  skipped,

  /// The engine failed on it.
  failed,
}

/// One phrase of a recording and what was heard in it.
final class TranscribedPhrase extends Equatable {
  const new({
    required this.index,
    required this.start,
    required this.end,
    required this.status,
    this.text = '',
    this.language,
  });

  /// [SpeechSegment.index].
  final int index;

  /// Where the phrase is in the recording.
  final Duration start;
  final Duration end;

  final PhraseStatus status;

  /// What was heard, trimmed.
  final String text;

  /// The app (BCP-47) code of the language it was heard in, when known.
  final String? language;

  /// Whether words were heard.
  bool get hasText => status == PhraseStatus.transcribed && text.isNotEmpty;

  @override
  List<Object?> get props => [index, start, end, status, text, language];
}

/// Joins the texts of consecutive phrases: with a space, but none next to
/// Chinese or Japanese characters (written without spaces).
String joinPhrases(Iterable<String> texts) {
  final buffer = StringBuffer();
  for (final text in texts) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) continue;
    if (buffer.isNotEmpty) {
      final previous = buffer.toString();
      final last = previous.runes.last;
      final first = trimmed.runes.first;
      if (!_isCjk(last) && !_isCjk(first)) buffer.write(' ');
    }
    buffer.write(trimmed);
  }
  return buffer.toString();
}

/// Han, kana and CJK punctuation / full-width forms.
bool _isCjk(int rune) =>
    (rune >= 0x3000 && rune <= 0x30ff) ||
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0xff00 && rune <= 0xffef) ||
    (rune >= 0x20000 && rune <= 0x2fa1f);

/// Transcribes a recording phrase by phrase while it is recorded: the
/// microphone's PCM16 chunks ([add]) are classified window by window
/// ([SpeechFrameClassifier], Silero VAD, or loudness as the `fallback`
/// when it fails), cut at pauses ([UtteranceSegmenter]) and each phrase is
/// transcribed as soon as it is over, one at a time, in order.
/// [onPhrase] receives every phrase in order; [onActivity] runs after each
/// chunk was classified (to check [silenceAfterSpeech], e.g. to stop after
/// a pause).
///
/// Memory stays bounded: the phrase in progress (at most
/// [UtteranceSegmenter.maxSegment]) and the phrases waiting for the engine,
/// at most [maxBacklog] of audio; a phrase beyond it is dropped
/// ([PhraseStatus.skipped]).
class PhraseTranscriber {
  new({
    required this._transcribe,
    required this._classifier,
    this._fallback,
    UtteranceSegmenter? segmenter,
    this.language,
    this.maxBacklog = const Duration(minutes: 2),
    this.onPhrase,
    this.onActivity,
    this._cancelEngine,
  }) : segmenter = segmenter ?? UtteranceSegmenter();

  final PhraseTranscribe _transcribe;
  SpeechFrameClassifier _classifier;
  SpeechFrameClassifier? _fallback;

  /// Stops a running transcription (e.g. `OfflineSpeech.cancel`).
  final Future<void> Function()? _cancelEngine;

  /// Cuts the recording into phrases.
  final UtteranceSegmenter segmenter;

  /// The Whisper code to transcribe in; null detects it per phrase.
  final String? language;

  /// The most audio waiting for the engine.
  final Duration maxBacklog;

  final void Function(TranscribedPhrase phrase)? onPhrase;
  final void Function()? onActivity;

  final Pcm16Decoder _decoder = Pcm16Decoder();
  final List<double> _window = [];
  final List<TranscribedPhrase> _phrases = [];
  Future<void> _classifying = Future.value();
  Future<void> _transcribing = Future.value();
  Duration _waiting = Duration.zero;
  int _queued = 0;
  bool _running = false;
  bool _finished = false;
  bool _cancelled = false;
  double _level = silenceDbfs;

  /// Loudness of the last chunk in dBFS.
  double get level => _level;

  /// Whether speech was heard so far.
  bool get heardSpeech => segmenter.heardSpeech;

  /// Silence since the last speech (zero before any).
  Duration get silenceAfterSpeech => segmenter.silenceAfterSpeech;

  /// The audio classified so far.
  Duration get recorded => segmenter.recorded;

  /// Phrases cut but not transcribed yet (also the one transcribing).
  int get pending => _queued;

  /// Whether the fallback classifier replaced the first one (it failed).
  bool get usesFallback => _fellBack;
  bool _fellBack = false;

  /// The phrases so far, in order.
  List<TranscribedPhrase> get phrases => List.unmodifiable(_phrases);

  /// The text of every phrase so far ([joinPhrases]).
  String get text => joinPhrases([
    for (final phrase in _phrases)
      if (phrase.hasText) phrase.text,
  ]);

  /// The language most of the speech so far was heard in (by duration),
  /// when the engine said.
  String? get heardLanguage => _dominantLanguage();

  /// Adds a chunk of the microphone's little-endian PCM16; ignored after
  /// [finish] or [cancel].
  void add(List<int> chunk) {
    if (_finished || _cancelled) return;
    addSamples(_decoder.convert(chunk));
  }

  /// Adds 16 kHz mono [samples] (`-1..1`, e.g. other apps' sound for live
  /// captions) like [add] does a PCM16 chunk; ignored after [finish] or
  /// [cancel].
  void addSamples(Float32List samples) {
    if (_finished || _cancelled) return;
    _level = rmsDbfs(samples);
    _window.addAll(samples);
    final whole = _window.length - _window.length % speechFrameSize;
    if (whole == 0) {
      _classifying = _classifying.then((_) => onActivity?.call());
      return;
    }
    final frames = Float32List.fromList(_window.sublist(0, whole));
    _window.removeRange(0, whole);
    _classifying = _classifying.then((_) => _classify(frames));
  }

  /// Ends the recording: the phrase in progress is cut and transcribed
  /// too. Completes with every phrase once all are transcribed.
  Future<List<TranscribedPhrase>> finish() async {
    if (!_finished) {
      _finished = true;
      await _classifying;
      if (segmenter.flush() case final segment? when !_cancelled) {
        _enqueue(segment);
      }
    }
    await _transcribing;
    return phrases;
  }

  /// Drops the recording: nothing more is transcribed or reported; a
  /// running transcription is stopped.
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _finished = true;
    if (_running) {
      try {
        await _cancelEngine?.call();
      } on Object {
        // The result is dropped either way.
      }
    }
  }

  Future<void> _classify(Float32List frames) async {
    if (_cancelled) return;
    List<double> probabilities;
    try {
      probabilities = await _classifier.classify(frames);
    } on Object {
      final fallback = _fallback;
      if (fallback == null) {
        // Without a classifier every window counts as speech: phrases are
        // then cut at the maximum length only.
        probabilities = List.filled(frames.length ~/ speechFrameSize, 1);
      } else {
        _classifier = fallback;
        _fallback = null;
        _fellBack = true;
        probabilities = await fallback.classify(frames);
      }
    }
    if (_cancelled) return;
    for (var i = 0; i < probabilities.length; i++) {
      final frame = Float32List.sublistView(
        frames,
        i * speechFrameSize,
        (i + 1) * speechFrameSize,
      );
      if (segmenter.add(frame, probabilities[i]) case final segment?) {
        _enqueue(segment);
      }
    }
    onActivity?.call();
  }

  void _enqueue(SpeechSegment segment) {
    // A phrase is never dropped while nothing else waits.
    final skip =
        _waiting > Duration.zero && _waiting + segment.duration > maxBacklog;
    if (!skip) _waiting += segment.duration;
    _queued++;
    _transcribing = _transcribing.then((_) => _run(segment, skip: skip));
  }

  Future<void> _run(SpeechSegment segment, {required bool skip}) async {
    if (!skip) _waiting -= segment.duration;
    var counted = false;
    try {
      if (_cancelled) return;
      final result = await _phraseOf(segment, skip: skip);
      // Not pending any more when reported.
      _queued--;
      counted = true;
      if (_cancelled) return;
      _phrases.add(result);
      onPhrase?.call(result);
    } finally {
      if (!counted) _queued--;
    }
  }

  Future<TranscribedPhrase> _phraseOf(
    SpeechSegment segment, {
    required bool skip,
  }) async {
    TranscribedPhrase phrase(
      PhraseStatus status, [
      String text = '',
      String? language,
    ]) => TranscribedPhrase(
      index: segment.index,
      start: segment.start,
      end: segment.end,
      status: status,
      text: text,
      language: language,
    );
    if (skip) return phrase(PhraseStatus.skipped);
    _running = true;
    try {
      final heard = await _transcribe(segment.samples, language: language);
      return phrase(
        PhraseStatus.transcribed,
        heard.text.trim(),
        languageForWhisper(heard.language),
      );
    } on Object {
      // Also when someone else cancelled the engine: the phrase is lost.
      return phrase(PhraseStatus.failed);
    } finally {
      _running = false;
    }
  }

  String? _dominantLanguage() {
    final durations = <String, Duration>{};
    for (final phrase in _phrases) {
      final code = phrase.language;
      if (!phrase.hasText || code == null) continue;
      durations[code] =
          (durations[code] ?? Duration.zero) + (phrase.end - phrase.start);
    }
    String? best;
    for (final MapEntry(key: code, value: duration) in durations.entries) {
      if (best == null || duration > durations[best]!) best = code;
    }
    return best;
  }
}
