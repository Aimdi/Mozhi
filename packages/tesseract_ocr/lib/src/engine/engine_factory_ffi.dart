import 'dart:ffi';
import 'dart:io';

import 'package:tesseract_ocr/src/engine/ffi/isolate_engine.dart';
import 'package:tesseract_ocr/src/engine/ocr_engine.dart';

/// Whether the native engine can run here: Android on arm64-v8a, x86_64 or
/// armeabi-v7a with NEON (the library is built with NEON, like the offline
/// translation engine). Other platforms need an explicit engine (tests).
bool get tesseractPlatformSupported => _supported ??= _detect();

bool? _supported;

bool _detect() {
  if (!Platform.isAndroid) return false;
  return switch (Abi.current()) {
    Abi.androidArm64 || Abi.androidX64 => true,
    Abi.androidArm => _hasNeon(),
    _ => false,
  };
}

bool _hasNeon() {
  try {
    return File('/proc/cpuinfo')
        .readAsLinesSync()
        .where((line) => line.toLowerCase().startsWith('features'))
        .any((line) => line.contains('neon') || line.contains('asimd'));
  } on Object {
    return false;
  }
}

/// The engine: a background isolate running `libmozhi_tesseract`.
OcrEngine createTesseractEngine({String? libraryPath}) =>
    IsolateTesseractEngine(libraryPath: libraryPath);
