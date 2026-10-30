import 'dart:typed_data';

import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:mozhi/voice/offline/speech_frames.dart';
import 'package:mozhi/voice/offline/utterance_segmenter.dart';
import 'package:whisper_speech/whisper_speech.dart';

/// Hears the phrases in a stream of audio, for live captions: one
/// recording per [start].
abstract interface class CaptionRecognizer {
  /// Whether a speech model is installed and the engine runs here.
  Future<bool> isReady();

  /// Starts a recording in [language] (an app code; null detects it per
  /// phrase); every phrase goes to [onPhrase], in order.
  Future<CaptionRecording> start({
    required void Function(TranscribedPhrase phrase) onPhrase,
    String? language,
  });
}

/// One recording of a [CaptionRecognizer].
abstract interface class CaptionRecording {
  /// Adds 16 kHz mono samples.
  void add(Float32List samples);

  /// Phrases waiting for the engine (also the one transcribing).
  int get pending;

  /// Ends the recording: the phrase in progress is transcribed too.
  Future<void> finish();

  /// Drops the recording and what waits for the engine.
  Future<void> cancel();
}

/// [CaptionRecognizer] with on-device Whisper ([OfflineSpeech]): the sound
/// is cut into phrases at pauses (Silero VAD when its model is installed,
/// else loudness) and each phrase is transcribed as soon as it is over
/// ([PhraseTranscriber]), on this device.
///
/// Captions must keep up, so phrases are short ([maxPhrase]: speech and
/// music rarely pause) and at most [maxBacklog] of audio waits for the
/// engine: beyond it a phrase is skipped rather than shown late.
class WhisperCaptionRecognizer implements CaptionRecognizer {
  new(this._speech);

  /// The pause that ends a phrase with the voice activity model.
  static const vadPause = Duration(milliseconds: 500);

  /// The pause that ends a phrase by loudness (more easily fooled).
  static const loudnessPause = Duration(milliseconds: 700);

  /// The longest phrase.
  static const maxPhrase = Duration(seconds: 8);

  /// The most audio waiting for the engine.
  static const maxBacklog = Duration(seconds: 20);

  final OfflineSpeech _speech;

  @override
  Future<bool> isReady() async {
    try {
      return await _speech.isReady();
    } on Object {
      return false;
    }
  }

  @override
  Future<CaptionRecording> start({
    required void Function(TranscribedPhrase phrase) onPhrase,
    String? language,
  }) async {
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
    return _WhisperRecording(
      PhraseTranscriber(
        transcribe: _speech.transcribe,
        classifier: classifier,
        fallback: vad ? LoudnessSpeechClassifier() : null,
        segmenter: UtteranceSegmenter(
          pause: vad ? vadPause : loudnessPause,
          maxSegment: maxPhrase,
          cutSearch: const Duration(seconds: 2),
        ),
        language: whisperLanguageFor(language),
        maxBacklog: maxBacklog,
        cancelEngine: _speech.cancel,
        onPhrase: onPhrase,
      ),
    );
  }
}

final class _WhisperRecording implements CaptionRecording {
  new(this._phrases);

  final PhraseTranscriber _phrases;

  @override
  void add(Float32List samples) => _phrases.addSamples(samples);

  @override
  int get pending => _phrases.pending;

  @override
  Future<void> finish() async {
    await _phrases.finish();
  }

  @override
  Future<void> cancel() => _phrases.cancel();
}
