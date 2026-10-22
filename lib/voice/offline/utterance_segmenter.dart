import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:mozhi/voice/offline/speech_frames.dart';

/// One phrase cut from a recording by [UtteranceSegmenter]: its audio
/// (with a little silence before and after) and where it is in the
/// recording.
final class SpeechSegment extends Equatable {
  const new({
    required this.index,
    required this.samples,
    required this.start,
    required this.end,
  });

  /// 0 for the recording's first phrase, then 1, 2, ...
  final int index;

  /// 16 kHz mono samples.
  final Float32List samples;

  /// Offset of the first sample in the recording.
  final Duration start;

  /// Offset just after the last sample.
  final Duration end;

  Duration get duration => end - start;

  @override
  List<Object?> get props => [index, start, end, samples.length];
}

/// Cuts a recording into phrases at pauses, from the speech probability
/// of each window of [speechFrameSize] samples (a [SpeechFrameClassifier]),
/// so each phrase can be transcribed as soon as it is over ("pseudo
/// streaming").
///
/// * A phrase starts at the first speech window (probability at least
///   [threshold]; it stays speech down to [releaseThreshold], so it does
///   not flicker), with [padding] of the audio before it.
/// * It ends after [pause] of silence, keeping [padding] of it. Phrases
///   with less than [minSpeech] of speech (a click, a cough) are dropped.
/// * A phrase longer than [maxSegment] (Whisper reads 30 s at a time) is
///   cut at the quietest window of its last [cutSearch], and the rest
///   starts the next phrase.
///
/// Memory is bounded: only the phrase in progress (at most [maxSegment])
/// and [padding] of silence are kept.
final class UtteranceSegmenter {
  new({
    this.pause = const Duration(milliseconds: 400),
    this.minSpeech = const Duration(milliseconds: 160),
    this.padding = const Duration(milliseconds: 200),
    this.maxSegment = const Duration(seconds: 25),
    this.cutSearch = const Duration(seconds: 3),
    this.threshold = 0.5,
    this.releaseThreshold = 0.35,
    this.sampleRate = 16000,
  }) : assert(releaseThreshold <= threshold, 'release above threshold'),
       assert(maxSegment > cutSearch, 'maxSegment must exceed cutSearch');

  /// Silence that ends a phrase.
  final Duration pause;

  /// Least speech in a phrase.
  final Duration minSpeech;

  /// Audio kept before and after the speech of a phrase.
  final Duration padding;

  /// Longest phrase.
  final Duration maxSegment;

  /// Where a phrase longer than [maxSegment] is cut: the quietest window
  /// of its last [cutSearch].
  final Duration cutSearch;

  /// Probability from which a window is speech.
  final double threshold;

  /// Probability below which speech ends.
  final double releaseThreshold;

  final int sampleRate;

  late final int _pauseFrames = math.max(1, _windows(pause));
  late final int _minSpeechFrames = math.max(1, _windows(minSpeech));
  late final int _paddingFrames = _windows(padding);
  late final int _maxFrames = math.max(2, _windows(maxSegment));
  late final int _cutFrames = math.max(1, _windows(cutSearch));

  int _windows(Duration duration) =>
      (duration.inMicroseconds * sampleRate / 1000000 / speechFrameSize).ceil();

  /// Silence before the phrase in progress (at most [padding]).
  final Queue<Float32List> _preRoll = Queue();

  /// The phrase in progress: its windows and their probabilities; empty
  /// between phrases.
  final List<Float32List> _phrase = [];
  final List<double> _probabilities = [];
  int _segmentStart = 0;
  int _speechFrames = 0;
  int _silentRun = 0;

  bool _speaking = false;
  int _frameCount = 0;
  int? _lastSpeechEnd;
  int _nextIndex = 0;

  /// Whether any window so far was speech.
  bool get heardSpeech => _lastSpeechEnd != null;

  /// Silence since the last speech window (zero before any speech and
  /// while speaking).
  Duration get silenceAfterSpeech =>
      _durationOf(_frameCount - (_lastSpeechEnd ?? _frameCount));

  /// The audio seen so far.
  Duration get recorded => _durationOf(_frameCount);

  /// Whether a phrase is in progress.
  bool get inPhrase => _phrase.isNotEmpty;

  /// Adds the next window ([speechFrameSize] samples) of the recording and
  /// its speech [probability]; returns the phrase it completes, if any.
  SpeechSegment? add(Float32List frame, double probability) {
    final index = _frameCount++;
    final speech = _speaking
        ? probability >= releaseThreshold
        : probability >= threshold;
    _speaking = speech;
    if (speech) _lastSpeechEnd = index + 1;

    if (_phrase.isEmpty) {
      if (!speech) {
        _preRoll.add(frame);
        while (_preRoll.length > _paddingFrames) {
          _preRoll.removeFirst();
        }
        return null;
      }
      _segmentStart = index - _preRoll.length;
      for (final silent in _preRoll) {
        _phrase.add(silent);
        _probabilities.add(0);
      }
      _preRoll.clear();
      _speechFrames = 0;
      _silentRun = 0;
    }
    _phrase.add(frame);
    _probabilities.add(probability);
    if (speech) {
      _speechFrames++;
      _silentRun = 0;
    } else {
      _silentRun++;
    }

    if (_silentRun >= _pauseFrames) return _endAtPause();
    if (_phrase.length >= _maxFrames) return _cutLong();
    return null;
  }

  /// Ends the recording: the phrase in progress, when it has enough
  /// speech. The segmenter can go on with another recording afterwards
  /// (its times continue).
  SpeechSegment? flush() {
    if (_phrase.isEmpty) return null;
    final silent = math.max(0, _silentRun - _paddingFrames);
    final segment = _speechFrames >= _minSpeechFrames
        ? _segment(_phrase.length - silent)
        : null;
    _clear();
    _speaking = false;
    return segment;
  }

  /// [pause] of silence: the phrase ends with [padding] of it; the rest of
  /// the silence is the next phrase's padding.
  SpeechSegment? _endAtPause() {
    final keep = math.min(
      _phrase.length,
      _phrase.length - _silentRun + _paddingFrames,
    );
    final segment = _speechFrames >= _minSpeechFrames ? _segment(keep) : null;
    _preRoll.addAll(_phrase.skip(keep));
    while (_preRoll.length > _paddingFrames) {
      _preRoll.removeFirst();
    }
    _clear();
    return segment;
  }

  /// [maxSegment] reached: cut after the quietest window of the last
  /// [cutSearch]; the windows after it start the next phrase.
  SpeechSegment? _cutLong() {
    final from = math.max(1, _phrase.length - _cutFrames);
    var cut = _phrase.length - 1;
    for (var i = from; i < _phrase.length; i++) {
      if (_probabilities[i] < _probabilities[cut]) cut = i;
    }
    final keep = cut + 1;
    final segment = _segment(keep);
    final restFrames = _phrase.sublist(keep);
    final restProbabilities = _probabilities.sublist(keep);
    final restStart = _segmentStart + keep;
    _clear();
    if (restFrames.isNotEmpty) {
      _phrase.addAll(restFrames);
      _probabilities.addAll(restProbabilities);
      _segmentStart = restStart;
      _speechFrames = restProbabilities.where((p) => p >= threshold).length;
      _silentRun = 0;
      for (final p in restProbabilities.reversed) {
        if (p >= releaseThreshold) break;
        _silentRun++;
      }
    }
    return segment;
  }

  /// The first [count] windows of the phrase in progress as a segment.
  SpeechSegment _segment(int count) {
    final samples = Float32List(count * speechFrameSize);
    for (var i = 0; i < count; i++) {
      samples.setAll(i * speechFrameSize, _phrase[i]);
    }
    return SpeechSegment(
      index: _nextIndex++,
      samples: samples,
      start: _durationOf(_segmentStart),
      end: _durationOf(_segmentStart + count),
    );
  }

  void _clear() {
    _phrase.clear();
    _probabilities.clear();
    _speechFrames = 0;
    _silentRun = 0;
  }

  Duration _durationOf(int frames) =>
      Duration(microseconds: frames * speechFrameSize * 1000000 ~/ sampleRate);
}
