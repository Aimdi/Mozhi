// Hand-written bindings for native/src/mozhi_whisper.h (keep in sync; the
// library reports MOZHI_WHISPER_ABI_VERSION, checked on load).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:whisper_speech/src/engine/cpu_features.dart';
import 'package:whisper_speech/src/engine/cpu_variant_guard.dart';

/// Opaque `MozhiWhisperModel`.
final class NativeWhisperModel extends Opaque;

/// Opaque `MozhiWhisperVad`.
final class NativeWhisperVad extends Opaque;

typedef _VadProcessNative = Int32 Function(
  Pointer<NativeWhisperVad> vad,
  Pointer<Float> samples,
  Int32 count,
  Pointer<Float> probabilities,
  Int32 maxProbabilities,
);

/// `mozhi_whisper_vad_process`.
typedef VadProcessFunction = int Function(
  Pointer<NativeWhisperVad> vad,
  Pointer<Float> samples,
  int count,
  Pointer<Float> probabilities,
  int maxProbabilities,
);

typedef _TranscribeNative = Pointer<Utf8> Function(
  Pointer<NativeWhisperModel> model,
  Pointer<Float> samples,
  Int32 count,
  Pointer<Utf8> language,
  Int32 threads,
  Pointer<Uint8> detected,
  Int32 detectedSize,
);

/// `mozhi_whisper_transcribe`.
typedef TranscribeFunction = Pointer<Utf8> Function(
  Pointer<NativeWhisperModel> model,
  Pointer<Float> samples,
  int count,
  Pointer<Utf8> language,
  int threads,
  Pointer<Uint8> detected,
  int detectedSize,
);

/// The functions of `libmozhi_whisper`.
final class WhisperBindings {
  new(DynamicLibrary library)
    : abiVersion = library.lookupFunction<Int32 Function(), int Function()>(
        'mozhi_whisper_abi_version',
      ),
      version = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_whisper_version',
          ),
      modelLoad = library
          .lookupFunction<
            Pointer<NativeWhisperModel> Function(Pointer<Utf8>, Int32),
            Pointer<NativeWhisperModel> Function(Pointer<Utf8>, int)
          >('mozhi_whisper_model_load'),
      modelFree = library
          .lookupFunction<
            Void Function(Pointer<NativeWhisperModel>),
            void Function(Pointer<NativeWhisperModel>)
          >('mozhi_whisper_model_free'),
      isMultilingual = library
          .lookupFunction<
            Int32 Function(Pointer<NativeWhisperModel>),
            int Function(Pointer<NativeWhisperModel>)
          >('mozhi_whisper_model_is_multilingual'),
      transcribe = library
          .lookupFunction<_TranscribeNative, TranscribeFunction>(
            'mozhi_whisper_transcribe',
          ),
      cancel = library.lookupFunction<Void Function(), void Function()>(
        'mozhi_whisper_cancel',
      ),
      freeString = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('mozhi_whisper_free_string'),
      lastError = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_whisper_last_error',
          ),
      vadLoad = library
          .lookupFunction<
            Pointer<NativeWhisperVad> Function(Pointer<Utf8>, Int32),
            Pointer<NativeWhisperVad> Function(Pointer<Utf8>, int)
          >('mozhi_whisper_vad_load'),
      vadFree = library
          .lookupFunction<
            Void Function(Pointer<NativeWhisperVad>),
            void Function(Pointer<NativeWhisperVad>)
          >('mozhi_whisper_vad_free'),
      vadFrameSize = library
          .lookupFunction<
            Int32 Function(Pointer<NativeWhisperVad>),
            int Function(Pointer<NativeWhisperVad>)
          >('mozhi_whisper_vad_frame_size'),
      vadProcess = library
          .lookupFunction<_VadProcessNative, VadProcessFunction>(
            'mozhi_whisper_vad_process',
          ),
      vadReset = library
          .lookupFunction<
            Void Function(Pointer<NativeWhisperVad>),
            void Function(Pointer<NativeWhisperVad>)
          >('mozhi_whisper_vad_reset');

  /// MOZHI_WHISPER_ABI_VERSION these bindings were written for.
  static const expectedAbiVersion = 2;

  /// File name of the baseline library (Android packs it into the APK per
  /// ABI; arm64-v8a also has the [WhisperLibraryVariant]s).
  static const libraryName = 'libmozhi_whisper.so';

  /// Environment variable with an explicit library path (desktop tests).
  static const libraryPathVariable = 'WHISPER_LIBRARY_PATH';

  /// `MOZHI_WHISPER_LANGUAGE_SIZE`.
  static const languageSize = 8;

  final int Function() abiVersion;
  final Pointer<Utf8> Function() version;
  final Pointer<NativeWhisperModel> Function(Pointer<Utf8> path, int threads)
  modelLoad;
  final void Function(Pointer<NativeWhisperModel> model) modelFree;
  final int Function(Pointer<NativeWhisperModel> model) isMultilingual;
  final TranscribeFunction transcribe;
  final void Function() cancel;
  final void Function(Pointer<Utf8> text) freeString;
  final Pointer<Utf8> Function() lastError;
  final Pointer<NativeWhisperVad> Function(Pointer<Utf8> path, int threads)
  vadLoad;
  final void Function(Pointer<NativeWhisperVad> vad) vadFree;
  final int Function(Pointer<NativeWhisperVad> vad) vadFrameSize;
  final VadProcessFunction vadProcess;
  final void Function(Pointer<NativeWhisperVad> vad) vadReset;

  /// Opens the library: [path], else `$WHISPER_LIBRARY_PATH`, else
  /// [libraryName] from the system search path (the APK on Android).
  static DynamicLibrary open([String? path]) => DynamicLibrary.open(
    path ?? Platform.environment[libraryPathVariable] ?? libraryName,
  );

  /// The library the engine should open: [path], else
  /// `$WHISPER_LIBRARY_PATH` ([environment]), else the fastest
  /// [WhisperLibraryVariant] for the CPU ([cpuFeatures], default
  /// [ArmCpuFeatures.current]) when it opens with [expectedAbiVersion]
  /// ([probe] returns the ABI version of a library, or throws when it
  /// cannot open it), else [libraryName] (the engine reports why it
  /// cannot open that one).
  ///
  /// Deterministic for a device, so every isolate that resolves it opens
  /// the same library.
  ///
  /// With [guard], a variant that crashed the app twice in a row before is
  /// not probed (the baseline runs), and a marker of [role] is written
  /// while one is probed ([CpuVariantGuard]).
  static String resolve({
    String? path,
    Map<String, String>? environment,
    ArmCpuFeatures? Function() cpuFeatures = ArmCpuFeatures.current,
    int Function(String library) probe = _abiVersionOf,
    CpuVariantGuard? guard,
    String role = 'open',
  }) {
    final explicit =
        path ?? (environment ?? Platform.environment)[libraryPathVariable];
    if (explicit != null) return explicit;
    final variant = WhisperLibraryVariant.forCpu(cpuFeatures());
    if (variant != WhisperLibraryVariant.baseline &&
        (guard?.candidates([variant.fileName]).isNotEmpty ?? true)) {
      guard?.arm(variant.fileName, role: role);
      try {
        if (probe(variant.fileName) == expectedAbiVersion) {
          return variant.fileName;
        }
      } on Object {
        // Missing from this build, or it does not load: the baseline runs.
      } finally {
        guard?.disarm(role: role);
      }
    }
    return libraryName;
  }

  static int _abiVersionOf(String library) =>
      WhisperBindings(DynamicLibrary.open(library)).abiVersion();
}

/// The builds of `libmozhi_whisper` (native/CMakeLists.txt): the baseline
/// for every CPU of the ABI and, on arm64-v8a, two with ggml's kernels for
/// newer CPUs, chosen by [WhisperBindings.resolve].
enum WhisperLibraryVariant {
  /// ARMv8.0-A on arm64-v8a (and the only build of armeabi-v7a and
  /// x86_64).
  baseline(WhisperBindings.libraryName),

  /// ARMv8.2-A with the int8 dot product and FP16 arithmetic.
  dotprod('libmozhi_whisper_dotprod.so'),

  /// ARMv8.6-A with those and the int8 matrix multiply.
  i8mm('libmozhi_whisper_i8mm.so');

  new(this.fileName);

  /// The fastest variant a CPU with [features] runs (contract §4): [i8mm]
  /// with i8mm, dotprod and FP16, [dotprod] with dotprod and FP16, else
  /// (or without features: not Android arm64) the [baseline].
  static WhisperLibraryVariant forCpu(ArmCpuFeatures? features) {
    if (features == null || !features.dotprod || !features.fp16) {
      return baseline;
    }
    return features.i8mm ? i8mm : dotprod;
  }

  /// File name of the library in the APK.
  final String fileName;
}
