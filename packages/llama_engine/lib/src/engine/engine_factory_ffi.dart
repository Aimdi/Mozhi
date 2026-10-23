import 'dart:ffi';
import 'dart:io';

import 'package:llama_engine/src/engine/cpu_features.dart';
import 'package:llama_engine/src/engine/ffi/bindings.dart';
import 'package:llama_engine/src/engine/ffi/isolate_engine.dart';
import 'package:llama_engine/src/engine/llama_engine.dart';

/// Whether the native engine can run here: Android on arm64-v8a or x86_64
/// (the library is built for them; there is no 32-bit build). Other
/// platforms need an explicit library (desktop tests).
bool get llamaPlatformSupported => _supported ??= _detect();

bool? _supported;

bool _detect() {
  if (!Platform.isAndroid) return false;
  return switch (Abi.current()) {
    Abi.androidArm64 || Abi.androidX64 => true,
    _ => false,
  };
}

/// The engine: a background isolate running `libmozhi_llama`. On arm64 it
/// loads the fastest build the CPU runs (`libmozhi_llama_i8mm.so` with
/// i8mm, dotprod and fp16; `libmozhi_llama_dotprod.so` with dotprod and
/// fp16), falling back to the baseline when that one fails to open.
/// [libraryPath] (or `$LLAMA_LIBRARY_PATH`) picks a library instead.
LlamaEngine createLlamaEngine({String? libraryPath}) => IsolateLlamaEngine(
  libraries: LlamaBindings.candidates(
    path: libraryPath,
    features: ArmCpuFeatures.current(),
  ),
);
