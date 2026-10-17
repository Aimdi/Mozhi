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
