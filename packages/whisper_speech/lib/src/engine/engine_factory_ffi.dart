import 'dart:ffi';
import 'dart:io';

import 'package:whisper_speech/src/engine/cpu_features.dart';
import 'package:whisper_speech/src/engine/cpu_variant_guard.dart';
import 'package:whisper_speech/src/engine/ffi/bindings.dart';
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
///
/// With [variantGuardDirectory] (the app's support directory), a faster
/// build that crashed the app is turned off for good and the baseline is
/// used ([CpuVariantGuard]).
WhisperEngine createWhisperEngine({
  String? libraryPath,
  String? variantGuardDirectory,
}) => IsolateWhisperEngine(
  libraryPath: libraryPath,
  variantGuard: variantGuardDirectory == null
      ? null
      : whisperVariantGuard(variantGuardDirectory),
);

/// The voice activity detector: another background isolate running
/// `libmozhi_whisper` (the same build as [createWhisperEngine]'s, with the
/// same guard).
WhisperVadEngine createWhisperVadEngine({
  String? libraryPath,
  String? variantGuardDirectory,
}) => IsolateWhisperVadEngine(
  libraryPath: libraryPath,
  variantGuard: variantGuardDirectory == null
      ? null
      : whisperVariantGuard(variantGuardDirectory),
);

/// The [CpuVariantGuard] of `libmozhi_whisper`'s faster builds in
/// [directory].
CpuVariantGuard whisperVariantGuard(String directory) => CpuVariantGuard(
  directory: directory,
  variants: {
    WhisperLibraryVariant.dotprod.fileName,
    WhisperLibraryVariant.i8mm.fileName,
  },
);

/// Which build of `libmozhi_whisper` the engine uses here, for support (the
/// voice input settings): the explicit library, else the fastest variant
/// for this CPU unless the guard in [variantGuardDirectory] turned it off,
/// else the baseline. Reads `/proc/cpuinfo` and the guard's state; opens
/// nothing (a variant missing from the app would still fall back).
WhisperEngineBuild whisperEngineBuild({
  String? libraryPath,
  String? variantGuardDirectory,
  ArmCpuFeatures? Function() cpuFeatures = ArmCpuFeatures.current,
  Map<String, String>? environment,
}) {
  final explicit =
      libraryPath ??
      (environment ??
          Platform.environment)[WhisperBindings.libraryPathVariable];
  final skipped = variantGuardDirectory == null
      ? const <String>{}
      : whisperVariantGuard(variantGuardDirectory).read().skipped;
  final turnedOff = [
    for (final variant in [
      WhisperLibraryVariant.i8mm,
      WhisperLibraryVariant.dotprod,
    ])
      if (skipped.contains(variant.fileName)) _variantOf(variant),
  ];
  if (explicit != null) {
    return WhisperEngineBuild(
      variant: WhisperCpuVariant.custom,
      library: explicit,
      skipped: turnedOff,
    );
  }
  var variant = WhisperLibraryVariant.forCpu(cpuFeatures());
  if (skipped.contains(variant.fileName)) {
    variant = WhisperLibraryVariant.baseline;
  }
  return WhisperEngineBuild(
    variant: _variantOf(variant),
    library: variant.fileName,
    skipped: turnedOff,
  );
}

WhisperCpuVariant _variantOf(WhisperLibraryVariant variant) =>
    switch (variant) {
      WhisperLibraryVariant.baseline => WhisperCpuVariant.baseline,
      WhisperLibraryVariant.dotprod => WhisperCpuVariant.dotprod,
      WhisperLibraryVariant.i8mm => WhisperCpuVariant.i8mm,
    };
