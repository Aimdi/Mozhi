import 'dart:typed_data';

import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/voice_activity.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Samples per window of a [SpeechFrameClassifier]: 512 (32 ms at 16 kHz),
/// the window of Silero VAD.
const speechFrameSize = 512;

/// Tells speech from silence in a recording, window by window
/// ([speechFrameSize] samples of 16 kHz mono audio), for
/// `UtteranceSegmenter`.
abstract interface class SpeechFrameClassifier {
  /// The speech probability (`0..1`) of each of the whole windows in
  /// [samples] (whose length is a multiple of [speechFrameSize]), in
  /// order. The classifier may keep state between calls (one recording).
  Future<List<double>> classify(Float32List samples);

  /// Starts a new recording.
  Future<void> reset();
}

/// [SpeechFrameClassifier] with whisper.cpp's Silero voice activity
/// detection ([OfflineSpeech.detectSpeech]): a neural network that hears
/// speech, not loudness, so noise, music or a fan do not count. Throws
/// what the detector throws, and [StateError] when the model does not
/// answer in [speechFrameSize] windows.
final class SileroSpeechClassifier implements SpeechFrameClassifier {
  new(this._speech);

  final OfflineSpeech _speech;

  @override
  Future<List<double>> classify(Float32List samples) async {
    final frames = await _speech.detectSpeech(samples);
    if (frames.frameSize != speechFrameSize ||
        frames.length != samples.length ~/ speechFrameSize) {
      throw StateError('Unexpected voice activity windows: $frames');
    }
    return frames.probabilities;
  }

  @override
  Future<void> reset() => _speech.resetSpeechDetection();
}

/// [SpeechFrameClassifier] by loudness ([VoiceActivityDetector]): a window
/// louder than the background is speech (1), anything else silence (0).
/// The fallback without the voice activity model; fooled by noise.
final class LoudnessSpeechClassifier implements SpeechFrameClassifier {
  new() : _detector = _newDetector();

  VoiceActivityDetector _detector;

  static VoiceActivityDetector _newDetector() =>
      VoiceActivityDetector(pause: Duration.zero);

  @override
  Future<List<double>> classify(Float32List samples) async {
    final probabilities = <double>[];
    for (var start = 0; start + speechFrameSize <= samples.length;) {
      final level = rmsDbfs(samples, start, start += speechFrameSize);
      probabilities.add(_detector.isSpeech(level) ? 1 : 0);
    }
    return probabilities;
  }

  @override
  Future<void> reset() async => _detector = _newDetector();
}
