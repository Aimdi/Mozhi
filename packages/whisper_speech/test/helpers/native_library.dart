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
