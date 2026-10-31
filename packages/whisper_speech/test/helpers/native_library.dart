import 'dart:io';

import 'package:path/path.dart' as p;

/// The native library for desktop tests: `$WHISPER_LIBRARY_PATH`, else the
/// output of `tool/build_native_linux.sh`. Null when neither exists.
String? nativeLibraryPath() {
  final fromEnvironment = Platform.environment['WHISPER_LIBRARY_PATH'];
  if (fromEnvironment != null && File(fromEnvironment).existsSync()) {
    return p.absolute(fromEnvironment);
  }
  final built = p.absolute('build', 'native', 'linux', 'libmozhi_whisper.so');
  return File(built).existsSync() ? built : null;
}

/// whisper.cpp's empty-weight test model (multilingual tiny layout, no
/// tensors: it loads and runs, and hears nothing).
String? testModelPath([String name = 'for-tests-ggml-tiny.bin']) {
  final path = p.absolute(
    'native',
    'third_party',
    'whisper.cpp',
    'models',
    name,
  );
  return File(path).existsSync() ? path : null;
}

/// Skip reason for tests that need the native library and the test model.
Object nativeLibrarySkip() {
  if (nativeLibraryPath() == null) {
    return 'libmozhi_whisper.so not built (tool/build_native_linux.sh)';
  }
  if (testModelPath() == null) {
    return 'whisper.cpp test models missing (tool/fetch_native_deps.sh)';
  }
  return false;
}

/// What `tool/fetch_test_model.py` puts in place for the real-transcription
/// tests: a real speech model of the catalogue (`$WHISPER_SPEECH_MODEL`,
/// else `build/test_models/ggml-tiny.bin`, the "Fast" model) and clear
/// English speech (`$WHISPER_SPEECH_SAMPLE`, else
/// `build/test_models/speech-en.wav`: whisper.cpp's samples/jfk.wav). Null
/// when missing.
String? speechModelPath() => _existing('WHISPER_SPEECH_MODEL', [
  'build',
  'test_models',
  'ggml-tiny.bin',
]);

/// See [speechModelPath].
String? speechSamplePath() => _existing('WHISPER_SPEECH_SAMPLE', [
  'build',
  'test_models',
  'speech-en.wav',
]);

/// Skip reason for tests that transcribe real speech with a real model.
Object realTranscriptionSkip() {
  if (nativeLibraryPath() == null) {
    return 'libmozhi_whisper.so not built (tool/build_native_linux.sh)';
  }
  if (speechModelPath() == null || speechSamplePath() == null) {
    return 'speech model or sample missing (tool/fetch_test_model.py)';
  }
  return false;
}

String? _existing(String variable, List<String> fallback) {
  final fromEnvironment = Platform.environment[variable];
  if (fromEnvironment != null && File(fromEnvironment).existsSync()) {
    return p.absolute(fromEnvironment);
  }
  final path = p.absolute(p.joinAll(fallback));
  return File(path).existsSync() ? path : null;
}
