import 'dart:ffi';
import 'dart:io';

import 'package:bergamot_translator/src/engine/bergamot_engine.dart';
import 'package:bergamot_translator/src/engine/ffi/isolate_engine.dart';
import 'package:bergamot_translator/src/engine/ffi/isolate_language_identifier.dart';
import 'package:bergamot_translator/src/engine/web/bergamot_worker.dart';
import 'package:bergamot_translator/src/native_language_identifier.dart';

/// Whether the native engine can run here: Android on arm64-v8a, x86_64 or
/// armeabi-v7a with VFPv4 (the library is built with NEON + VFPv4; older
/// Cortex-A8/A9 cores would crash). Other platforms need an explicit
/// engine (tests).
bool get bergamotPlatformSupported => _supported ??= _detect();

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

/// The engine: a background isolate running `libmozhi_bergamot`.
BergamotEngine createBergamotEngine({
  String? libraryPath,
  int maxLoadedModels = 3,
}) => IsolateBergamotEngine(
  libraryPath: libraryPath,
  maxLoadedModels: maxLoadedModels,
);

/// The language identifier: CLD2 in `libmozhi_bergamot`, run in a
/// background isolate per call.
NativeLanguageIdentifier createNativeLanguageIdentifier({
  String? libraryPath,
}) => IsolateLanguageIdentifier(libraryPath: libraryPath);

/// The web engine's worker: none outside a browser.
BergamotWorkerChannel? openBergamotWorker({
  String url = defaultBergamotWorkerUrl,
}) => null;

/// Persistent browser storage: there is none outside a browser.
Future<bool> requestPersistentBrowserStorage() async => false;
