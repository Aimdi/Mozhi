import 'dart:ffi';
import 'dart:io';

import 'package:llama_engine/src/engine/cpu_features.dart';
import 'package:llama_engine/src/engine/cpu_variant_guard.dart';
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
///
/// With [variantGuardDirectory] (the app's support directory), a faster
/// build that crashed the app twice in a row is turned off for good and
/// the next one (in the end the baseline) is used ([CpuVariantGuard]).
LlamaEngine createLlamaEngine({
  String? libraryPath,
  String? variantGuardDirectory,
}) => IsolateLlamaEngine(
  libraries: LlamaBindings.candidates(
    path: libraryPath,
    features: ArmCpuFeatures.current(),
  ),
  variantGuard: variantGuardDirectory == null
      ? null
      : llamaVariantGuard(variantGuardDirectory),
);

/// The [CpuVariantGuard] of `libmozhi_llama`'s faster builds in
/// [directory].
CpuVariantGuard llamaVariantGuard(String directory) => CpuVariantGuard(
  directory: directory,
  variants: const {
    LlamaBindings.dotprodLibraryName,
    LlamaBindings.i8mmLibraryName,
  },
);

/// Which build of `libmozhi_llama` the engine uses here, for support (the
/// On-device AI page): the first of the candidates for this CPU that the
/// guard in [variantGuardDirectory] has not turned off. Reads
/// `/proc/cpuinfo` and the guard's state; opens nothing.
LlamaEngineBuild llamaEngineBuild({
  String? libraryPath,
  String? variantGuardDirectory,
  ArmCpuFeatures? Function() cpuFeatures = ArmCpuFeatures.current,
  Map<String, String>? environment,
}) {
  final candidates = LlamaBindings.candidates(
    path: libraryPath,
    features: cpuFeatures(),
    environment: environment,
  );
  final guard = variantGuardDirectory == null
      ? null
      : llamaVariantGuard(variantGuardDirectory);
  final skipped = guard?.read().skipped ?? const <String>{};
  // The baseline (or an explicit library) is never skipped: it is found.
  final library = candidates.firstWhere(
    (candidate) => !skipped.contains(candidate),
    orElse: () => LlamaBindings.libraryName, // coverage:ignore-line
  );
  return LlamaEngineBuild(
    variant: switch (library) {
      LlamaBindings.libraryName => LlamaCpuVariant.baseline,
      LlamaBindings.dotprodLibraryName => LlamaCpuVariant.dotprod,
      LlamaBindings.i8mmLibraryName => LlamaCpuVariant.i8mm,
      _ => LlamaCpuVariant.custom,
    },
    library: library,
    skipped: [
      for (final variant in [
        LlamaBindings.i8mmLibraryName,
        LlamaBindings.dotprodLibraryName,
      ])
        if (skipped.contains(variant)) ?_variantOf(variant),
    ],
  );
}

LlamaCpuVariant? _variantOf(String library) => switch (library) {
  LlamaBindings.dotprodLibraryName => LlamaCpuVariant.dotprod,
  LlamaBindings.i8mmLibraryName => LlamaCpuVariant.i8mm,
  _ => null,
};
