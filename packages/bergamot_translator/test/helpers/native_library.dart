import 'dart:io';

import 'package:path/path.dart' as p;

/// The native library for desktop tests: `$BERGAMOT_LIBRARY_PATH`, else the
/// output of `tool/build_native_linux.sh`. Null when neither exists.
String? nativeLibraryPath() {
  final fromEnvironment = Platform.environment['BERGAMOT_LIBRARY_PATH'];
  if (fromEnvironment != null && File(fromEnvironment).existsSync()) {
    return p.absolute(fromEnvironment);
  }
  final built = p.absolute('build', 'native', 'linux', 'libmozhi_bergamot.so');
  return File(built).existsSync() ? built : null;
}

/// Skip reason for tests that need the native library.
Object nativeLibrarySkip() => nativeLibraryPath() == null
    ? 'libmozhi_bergamot.so not built (tool/build_native_linux.sh)'
    : false;
