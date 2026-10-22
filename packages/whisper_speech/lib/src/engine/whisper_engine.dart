import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The native engine failed (it could not be loaded, a model could not be
/// opened, or a transcription failed). The message comes from the engine.
class WhisperEngineException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'WhisperEngineException($message)';
}

/// A transcription was stopped by [WhisperEngine.cancel].
final class WhisperCancelledException extends WhisperEngineException {
  const new() : super('cancelled');

  @override
  String toString() => 'WhisperCancelledException()';
}

/// What Whisper heard.
@immutable
final class WhisperTranscription {
  const new(this.text, {this.language});

  /// The text, trimmed; empty for silence.
  final String text;

  /// The Whisper code of the language it was transcribed in (the detected
  /// one when the language was `auto`), or null when unknown.
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is WhisperTranscription &&
      other.text == text &&
      other.language == language;

  @override
  int get hashCode => Object.hash(text, language);

  @override
  String toString() => 'WhisperTranscription($language, ${text.length} chars)';
}

/// Runs whisper.cpp (`libmozhi_whisper`), off the UI isolate.
///
/// Implementations load a model file on first use and keep it loaded for
/// later calls (one model at a time).
abstract interface class WhisperEngine {
  /// Transcribes [samples] (16 kHz mono, `-1..1`) with the model file at
  /// [modelPath] in [language] (a Whisper code; null or `auto` detects
  /// it). [threads] <= 0 uses the engine's default (at most 4).
  ///
  /// Throws [WhisperCancelledException] when [cancel] stopped it and
  /// [WhisperEngineException] when it failed.
  Future<WhisperTranscription> transcribe(
    String modelPath,
    Float32List samples, {
    String? language,
    int threads = 0,
  });

  /// Stops every transcription that is running or waiting.
  Future<void> cancel();

  /// Unloads the model at [modelPath] if it is loaded (e.g. before deleting
  /// the file).
  Future<void> release(String modelPath);

  /// Unloads the model and stops the background isolate. The engine stays
  /// usable; the next call starts it again.
  Future<void> dispose();
}

/// Speech probabilities of consecutive windows of an audio stream, as
/// [WhisperVadEngine.detect] returns them.
@immutable
final class WhisperVadFrames {
  const new(this.probabilities, {required this.frameSize});

  /// No complete window yet.
  static final empty = WhisperVadFrames(Float32List(0), frameSize: 512);

  /// The speech probability (`0..1`) of each window, oldest first.
  final Float32List probabilities;

  /// Samples per window: 512 (32 ms at 16 kHz) for Silero v5 and v6.
  final int frameSize;

  /// Number of windows.
  int get length => probabilities.length;

  @override
  String toString() => 'WhisperVadFrames($length x $frameSize)';
}

/// Runs whisper.cpp's Silero voice activity detection (`libmozhi_whisper`)
/// on an audio stream, off the UI isolate and apart from [WhisperEngine]
/// (it keeps up with the microphone while a recording is transcribed).
///
/// The detector keeps the state of one stream between calls: feed it the
/// recording chunk by chunk with [detect] and [reset] it before the next
/// recording.
abstract interface class WhisperVadEngine {
  /// Feeds [samples] (16 kHz mono, `-1..1`) of the stream to the detector
  /// with the model file at [modelPath] (loaded on first use) and returns
  /// the speech probability of every window they complete. Samples that do
  /// not fill a window yet are kept for the next call.
  ///
  /// Throws [WhisperEngineException] when the model cannot be loaded or
  /// detection fails.
  Future<WhisperVadFrames> detect(String modelPath, Float32List samples);

  /// Forgets the stream: the next [detect] starts a new one.
  Future<void> reset();

  /// Unloads the model at [modelPath] if it is loaded (e.g. before deleting
  /// the file).
  Future<void> release(String modelPath);

  /// Unloads the model and stops the background isolate. The engine stays
  /// usable; the next call starts it again.
  Future<void> dispose();
}
