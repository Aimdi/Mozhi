// Hand-written bindings for native/src/mozhi_bergamot.h (keep in sync; the
// library reports MOZHI_BERGAMOT_ABI_VERSION, checked on load).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque `MozhiBergamotModel`.
final class NativeModel extends Opaque;

/// `MozhiBergamotLanguage`: one language found by `mozhi_bergamot_detect`.
final class NativeLanguage extends Struct {
  /// NUL-terminated ASCII code.
  @Array(BergamotBindings.codeLength)
  external Array<Uint8> code;

  @Int32()
  external int percent;

  @Int32()
  external int score;
}

/// `MozhiBergamotDetection`: the result of `mozhi_bergamot_detect`.
final class NativeDetection extends Struct {
  /// NUL-terminated ASCII code of CLD2's answer.
  @Array(BergamotBindings.codeLength)
  external Array<Uint8> language;

  @Array(3)
  external Array<NativeLanguage> languages;

  @Int32()
  external int textBytes;

  @Int32()
  external int reliable;
}

typedef _DetectNative = Int32 Function(
  Pointer<Uint8> text,
  Int32 length,
  Pointer<Utf8> hints,
  Int32 flags,
  Pointer<NativeDetection> out,
);
typedef DetectFunction = int Function(
  Pointer<Uint8> text,
  int length,
  Pointer<Utf8> hints,
  int flags,
  Pointer<NativeDetection> out,
);

/// The functions of `libmozhi_bergamot`.
final class BergamotBindings {
  new(DynamicLibrary library)
    : abiVersion = library.lookupFunction<Int32 Function(), int Function()>(
        'mozhi_bergamot_abi_version',
      ),
      version = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_bergamot_version',
          ),
      modelCreate = library
          .lookupFunction<
            Pointer<NativeModel> Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            ),
            Pointer<NativeModel> Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            )
          >('mozhi_bergamot_model_create'),
      modelDestroy = library
          .lookupFunction<
            Void Function(Pointer<NativeModel>),
            void Function(Pointer<NativeModel>)
          >('mozhi_bergamot_model_destroy'),
      translate = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<NativeModel>, Pointer<Utf8>, Int32),
            Pointer<Utf8> Function(Pointer<NativeModel>, Pointer<Utf8>, int)
          >('mozhi_bergamot_translate'),
      translatePivot = library
          .lookupFunction<
            Pointer<Utf8> Function(
              Pointer<NativeModel>,
              Pointer<NativeModel>,
              Pointer<Utf8>,
              Int32,
            ),
            Pointer<Utf8> Function(
              Pointer<NativeModel>,
              Pointer<NativeModel>,
              Pointer<Utf8>,
              int,
            )
          >('mozhi_bergamot_translate_pivot'),
      freeString = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('mozhi_bergamot_free_string'),
      lastError = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_bergamot_last_error',
          ),
      detect = library.providesSymbol(detectSymbol)
          ? library.lookupFunction<_DetectNative, DetectFunction>(detectSymbol)
          : null;

  /// MOZHI_BERGAMOT_ABI_VERSION these bindings were written for.
  static const expectedAbiVersion = 1;

  /// File name of the library (Android packs it into the APK per ABI).
  static const libraryName = 'libmozhi_bergamot.so';

  /// Environment variable with an explicit library path (desktop tests).
  static const libraryPathVariable = 'BERGAMOT_LIBRARY_PATH';

  /// The language identifier, added to ABI 1 later: libraries built before
  /// it do not have it.
  static const detectSymbol = 'mozhi_bergamot_detect';

  /// Size of the code fields of [NativeLanguage] and [NativeDetection].
  static const codeLength = 16;

  /// `MOZHI_BERGAMOT_DETECT_BEST_EFFORT`.
  static const detectBestEffort = 1;

  final int Function() abiVersion;
  final Pointer<Utf8> Function() version;
  final Pointer<NativeModel> Function(
    Pointer<Utf8> model,
    Pointer<Utf8> shortlist,
    Pointer<Utf8> sourceVocab,
    Pointer<Utf8> targetVocab,
    Pointer<Utf8> extraConfig,
  )
  modelCreate;
  final void Function(Pointer<NativeModel> model) modelDestroy;
  final Pointer<Utf8> Function(
    Pointer<NativeModel> model,
    Pointer<Utf8> text,
    int html,
  )
  translate;
  final Pointer<Utf8> Function(
    Pointer<NativeModel> first,
    Pointer<NativeModel> second,
    Pointer<Utf8> text,
    int html,
  )
  translatePivot;
  final void Function(Pointer<Utf8> text) freeString;
  final Pointer<Utf8> Function() lastError;

  /// `mozhi_bergamot_detect`, or null when the library predates it.
  final DetectFunction? detect;

  /// Opens the library: [path], else `$BERGAMOT_LIBRARY_PATH`, else
  /// [libraryName] from the system search path (the APK on Android).
  static DynamicLibrary open([String? path]) => DynamicLibrary.open(
    path ?? Platform.environment[libraryPathVariable] ?? libraryName,
  );
}
