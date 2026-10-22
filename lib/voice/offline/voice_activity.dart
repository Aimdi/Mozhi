import 'dart:math' as math;

/// Tells speech from silence by loudness, so a recording for an offline
/// engine can stop after a pause (like the system recogniser does) and
/// silence is not transcribed at all (Whisper tends to "hear" a word or
/// two in it).
///
/// A chunk counts as speech when it is louder than [speechThreshold] dBFS
/// and either at least [margin] dB louder than the quietest chunk so far
/// (the background noise) or loud in any case (`speechThreshold + margin`,
/// for speech from the first chunk on and noisy places). Digital silence
/// (at or below -90 dBFS, e.g. the first buffer of a stream) does not count
/// as background noise.
final class VoiceActivityDetector {
  new({
    required this.pause,
    this.sampleRate = 16000,
    this.speechThreshold = -55,
    this.margin = 10,
  });

  /// Silence after speech that ends the utterance.
  final Duration pause;
  final int sampleRate;

  /// Quietest level that may be speech, in dBFS.
  final double speechThreshold;

  /// How much louder than the background speech is, in dB.
  final double margin;

  double? _floor;
  bool _heardSpeech = false;
  int _quietSamples = 0;

  /// Whether any chunk so far was speech.
  bool get heardSpeech => _heardSpeech;

  /// Whether speech was followed by [pause] of silence.
  bool get pausedAfterSpeech =>
      _heardSpeech &&
      _quietSamples * Duration.microsecondsPerSecond ~/ sampleRate >=
          pause.inMicroseconds;

  /// Adds a chunk of [samples] samples whose loudness is [level] dBFS.
  void add(double level, int samples) {
    if (!level.isFinite || samples <= 0) return;
    if (isSpeech(level)) {
      _heardSpeech = true;
      _quietSamples = 0;
    } else {
      _quietSamples += samples;
    }
  }

  /// Whether a chunk of loudness [level] dBFS is speech; it also counts
  /// towards the background noise level (as in [add], which uses it).
  bool isSpeech(double level) {
    if (!level.isFinite) return false;
    if (level > -90) _floor = math.min(_floor ?? level, level);
    final floor = _floor ?? level;
    return level >= speechThreshold &&
        (level >= floor + margin || level >= speechThreshold + margin);
  }
}
