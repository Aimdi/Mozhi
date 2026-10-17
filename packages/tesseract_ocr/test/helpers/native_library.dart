import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The tessdata_fast commit of `assets/catalog.json`.
const tessdataCommit = '87416418657359cb625c412a48b6e1d6d41c29bd';

/// The native library for desktop tests: `$TESSERACT_LIBRARY_PATH`, else
/// the output of `tool/build_native_linux.sh`. Null when neither exists.
String? nativeLibraryPath() {
  final fromEnvironment = Platform.environment['TESSERACT_LIBRARY_PATH'];
  if (fromEnvironment != null && File(fromEnvironment).existsSync()) {
    return p.absolute(fromEnvironment);
  }
  final built = p.absolute('build', 'native', 'linux', 'libmozhi_tesseract.so');
  return File(built).existsSync() ? built : null;
}

/// A directory with `eng.traineddata` for the real-engine tests:
/// `$TESSERACT_TEST_TESSDATA`, else `build/test_tessdata`, else the cache
/// of `tool/tessdata_catalog.py`. Null when none has it.
String? englishTessdataPath() {
  final candidates = [
    ?Platform.environment['TESSERACT_TEST_TESSDATA'],
    p.join('build', 'test_tessdata'),
    p.join('build', 'tessdata_cache', tessdataCommit),
  ];
  for (final directory in candidates) {
    if (File(p.join(directory, 'eng.traineddata')).existsSync()) {
      return p.absolute(directory);
    }
  }
  return null;
}

/// Skip reason for tests that need the native library.
Object nativeLibrarySkip() => nativeLibraryPath() == null
    ? 'libmozhi_tesseract.so not built (tool/build_native_linux.sh)'
    : false;

/// Skip reason for tests that need the library and English data.
Object realEngineSkip() {
  if (nativeLibraryPath() == null) return nativeLibrarySkip();
  return englishTessdataPath() == null
      ? 'eng.traineddata not found (see README: Building and testing)'
      : false;
}

/// A binary PGM (P5, maxval 255) image from `test/fixtures`.
({Uint8List pixels, int width, int height}) readPgm(String name) {
  final bytes = File(p.join('test', 'fixtures', name)).readAsBytesSync();
  final fields = <String>[];
  var offset = 0;
  while (fields.length < 4) {
    while (_isSpace(bytes[offset])) {
      offset++;
    }
    final start = offset;
    while (!_isSpace(bytes[offset])) {
      offset++;
    }
    fields.add(String.fromCharCodes(bytes.sublist(start, offset)));
  }
  offset++; // The single whitespace before the pixels.
  if (fields[0] != 'P5' || fields[3] != '255') {
    throw FormatException('Not an 8-bit binary PGM', name);
  }
  final width = int.parse(fields[1]);
  final height = int.parse(fields[2]);
  return (
    pixels: Uint8List.sublistView(bytes, offset, offset + width * height),
    width: width,
    height: height,
  );
}

/// [gray] as premultiplied RGBA (opaque).
Uint8List grayToRgba(Uint8List gray) {
  final rgba = Uint8List(gray.length * 4);
  for (var i = 0; i < gray.length; i++) {
    rgba
      ..[i * 4] = gray[i]
      ..[i * 4 + 1] = gray[i]
      ..[i * 4 + 2] = gray[i]
      ..[i * 4 + 3] = 255;
  }
  return rgba;
}

bool _isSpace(int byte) =>
    byte == 0x20 || byte == 0x0a || byte == 0x0d || byte == 0x09;
