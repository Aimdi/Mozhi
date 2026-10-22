import 'dart:typed_data';

import 'package:whisper_speech/src/engine/whisper_engine.dart';

/// Whether the native engine can run here: never on the web.
bool get whisperPlatformSupported => false;

/// An engine that is not available on this platform.
WhisperEngine createWhisperEngine({String? libraryPath}) =>
    const UnsupportedWhisperEngine();

/// A voice activity detector that is not available on this platform.
WhisperVadEngine createWhisperVadEngine({String? libraryPath}) =>
    const UnsupportedWhisperVadEngine();

/// The engine on platforms without `dart:ffi` (web): every call fails.
final class UnsupportedWhisperEngine implements WhisperEngine {
  const new();

  @override
  Future<WhisperTranscription> transcribe(
    String modelPath,
    Float32List samples, {
    String? language,
    int threads = 0,
  }) => Future.error(
    const WhisperEngineException(
      'Offline speech recognition is not available on the web',
    ),
  );

  @override
  Future<void> cancel() async {}

  @override
  Future<void> release(String modelPath) async {}

  @override
  Future<void> dispose() async {}
}

/// The voice activity detector on platforms without `dart:ffi` (web):
/// detection fails.
final class UnsupportedWhisperVadEngine implements WhisperVadEngine {
  const new();

  @override
  Future<WhisperVadFrames> detect(String modelPath, Float32List samples) =>
      Future.error(
        const WhisperEngineException(
          'Voice activity detection is not available on the web',
        ),
      );

  @override
  Future<void> reset() async {}

  @override
  Future<void> release(String modelPath) async {}

  @override
  Future<void> dispose() async {}
}
