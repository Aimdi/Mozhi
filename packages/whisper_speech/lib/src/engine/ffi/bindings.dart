// Hand-written bindings for native/src/mozhi_whisper.h (keep in sync; the
// library reports MOZHI_WHISPER_ABI_VERSION, checked on load).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque `MozhiWhisperModel`.
final class NativeWhisperModel extends Opaque;

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
          );

  /// MOZHI_WHISPER_ABI_VERSION these bindings were written for.
  static const expectedAbiVersion = 1;

  /// File name of the library (Android packs it into the APK per ABI).
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

  /// Opens the library: [path], else `$WHISPER_LIBRARY_PATH`, else
  /// [libraryName] from the system search path (the APK on Android).
  static DynamicLibrary open([String? path]) => DynamicLibrary.open(
    path ?? Platform.environment[libraryPathVariable] ?? libraryName,
  );
}
