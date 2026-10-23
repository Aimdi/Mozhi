import 'dart:ffi';
import 'dart:io';

import 'package:whisper_speech/src/engine/ffi/isolate_engine.dart';
import 'package:whisper_speech/src/engine/whisper_engine.dart';

/// Whether the native engine can run here: Android on arm64-v8a, x86_64 or
/// armeabi-v7a with NEON and VFPv4 (the library is built for them; older
/// Cortex-A8/A9 cores would crash). Other platforms need an explicit
/// engine (tests).
bool get whisperPlatformSupported => _supported ??= _detect();

bool? _supported;

bool _detect() {
  if (!Platform.isAndroid) return false;
  return switch (Abi.current()) {
    Abi.androidArm64 || Abi.androidX64 => true,
    Abi.androidArm => _hasVfpv4(),
    _ => false,
  };
}

bool _hasVfpv4() {
  try {
    final features = File('/proc/cpuinfo')
        .readAsLinesSync()
        .where((line) => line.toLowerCase().startsWith('features'))
        .join(' ');
    return features.contains('vfpv4') && features.contains('neon');
  } on Object {
    return false;
  }
}

/// The engine: a background isolate running `libmozhi_whisper` ([libraryPath],
/// else the fastest build the CPU runs: `libmozhi_whisper_i8mm.so` or
/// `libmozhi_whisper_dotprod.so` on newer arm64 phones, falling back to
/// the baseline `libmozhi_whisper.so`; see `WhisperBindings.resolve`).
WhisperEngine createWhisperEngine({String? libraryPath}) =>
    IsolateWhisperEngine(libraryPath: libraryPath);

/// The voice activity detector: another background isolate running
/// `libmozhi_whisper` (the same build as [createWhisperEngine]'s).
WhisperVadEngine createWhisperVadEngine({String? libraryPath}) =>
    IsolateWhisperVadEngine(libraryPath: libraryPath);
