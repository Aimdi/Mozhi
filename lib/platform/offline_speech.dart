// Offline voice input (Whisper, packages/whisper_speech) in every build.
// The engine needs dart:io and dart:ffi, so the web gets a stub without
// offline speech recognition.
export 'offline_speech_web.dart' if (dart.library.io) 'offline_speech_io.dart';
