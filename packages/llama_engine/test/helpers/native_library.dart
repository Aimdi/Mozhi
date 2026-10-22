import 'dart:io';

import 'package:path/path.dart' as p;

/// The native library for desktop tests: `$LLAMA_LIBRARY_PATH`, else the
/// output of `tool/build_native_linux.sh`. Null when neither exists.
String? nativeLibraryPath() {
  final fromEnvironment = Platform.environment['LLAMA_LIBRARY_PATH'];
  if (fromEnvironment != null && File(fromEnvironment).existsSync()) {
    return p.absolute(fromEnvironment);
  }
  final built = p.absolute('build', 'native', 'linux', 'libmozhi_llama.so');
  return File(built).existsSync() ? built : null;
}

/// A model written by `tool/make_test_model.py --all build/test_models`
/// (or `$LLAMA_TEST_MODELS`) with the chat template [template]: chatml,
/// qwen3, gemma4, hunyuan-dense or none. Null when it is missing.
String? testModelPath([String template = 'chatml']) {
  final directory =
      Platform.environment['LLAMA_TEST_MODELS'] ??
      p.absolute('build', 'test_models');
  final path = p.join(directory, 'llama-test-$template.gguf');
  return File(path).existsSync() ? p.absolute(path) : null;
}

/// Skip reason for tests that need the native library and the test models.
Object nativeLibrarySkip() {
  if (nativeLibraryPath() == null) {
    return 'libmozhi_llama.so not built (tool/build_native_linux.sh)';
  }
  for (final template in [
    'chatml',
    'qwen3',
    'gemma4',
    'hunyuan-dense',
    'none',
  ]) {
    if (testModelPath(template) == null) {
      return 'test models missing '
          '(tool/make_test_model.py --all build/test_models)';
    }
  }
  return false;
}
