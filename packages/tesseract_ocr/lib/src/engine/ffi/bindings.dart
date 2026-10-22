// Hand-written bindings for native/src/mozhi_tesseract.h (keep in sync; the
// library reports MOZHI_TESSERACT_ABI_VERSION, checked on load).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque `MozhiTesseract`.
final class NativeTesseract extends Opaque;

typedef _RecognizeNative = Pointer<Utf8> Function(
  Pointer<NativeTesseract> engine,
  Pointer<Uint8> pixels,
  Int32 width,
  Int32 height,
  Int32 bytesPerPixel,
  Int32 bytesPerLine,
  Pointer<Int32> meanConfidence,
);

typedef _RecognizeLayoutNative = Pointer<Utf8> Function(
  Pointer<NativeTesseract> engine,
  Pointer<Uint8> pixels,
  Int32 width,
  Int32 height,
  Int32 bytesPerPixel,
  Int32 bytesPerLine,
  Int32 flags,
);

/// `mozhi_tesseract_recognize_layout`.
typedef RecognizeLayoutFunction = Pointer<Utf8> Function(
  Pointer<NativeTesseract> engine,
  Pointer<Uint8> pixels,
  int width,
  int height,
  int bytesPerPixel,
  int bytesPerLine,
  int flags,
);

/// `mozhi_tesseract_recognize`.
typedef RecognizeFunction = Pointer<Utf8> Function(
  Pointer<NativeTesseract> engine,
  Pointer<Uint8> pixels,
  int width,
  int height,
  int bytesPerPixel,
  int bytesPerLine,
  Pointer<Int32> meanConfidence,
);

/// The functions of `libmozhi_tesseract`.
final class TesseractBindings {
  new(DynamicLibrary library)
    : abiVersion = library.lookupFunction<Int32 Function(), int Function()>(
        'mozhi_tesseract_abi_version',
      ),
      version = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_tesseract_version',
          ),
      create = library
          .lookupFunction<
            Pointer<NativeTesseract> Function(Pointer<Utf8>, Pointer<Utf8>),
            Pointer<NativeTesseract> Function(Pointer<Utf8>, Pointer<Utf8>)
          >('mozhi_tesseract_create'),
      destroy = library
          .lookupFunction<
            Void Function(Pointer<NativeTesseract>),
            void Function(Pointer<NativeTesseract>)
          >('mozhi_tesseract_destroy'),
      recognize = library.lookupFunction<_RecognizeNative, RecognizeFunction>(
        'mozhi_tesseract_recognize',
      ),
      recognizeLayout = library
          .lookupFunction<_RecognizeLayoutNative, RecognizeLayoutFunction>(
            'mozhi_tesseract_recognize_layout',
          ),
      freeString = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('mozhi_tesseract_free_string'),
      lastError = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_tesseract_last_error',
          );

  /// MOZHI_TESSERACT_ABI_VERSION these bindings were written for.
  static const expectedAbiVersion = 2;

  /// MOZHI_TESSERACT_LAYOUT_WORDS: [recognizeLayout] reports the words too.
  static const layoutWords = 1;

  /// File name of the library (Android packs it into the APK per ABI).
  static const libraryName = 'libmozhi_tesseract.so';

  /// Environment variable with an explicit library path (desktop tests).
  static const libraryPathVariable = 'TESSERACT_LIBRARY_PATH';

  final int Function() abiVersion;
  final Pointer<Utf8> Function() version;
  final Pointer<NativeTesseract> Function(
    Pointer<Utf8> datapath,
    Pointer<Utf8> languages,
  )
  create;
  final void Function(Pointer<NativeTesseract> engine) destroy;
  final RecognizeFunction recognize;
  final RecognizeLayoutFunction recognizeLayout;
  final void Function(Pointer<Utf8> text) freeString;
  final Pointer<Utf8> Function() lastError;

  /// Opens the library: [path], else `$TESSERACT_LIBRARY_PATH`, else
  /// [libraryName] from the system search path (the APK on Android).
  static DynamicLibrary open([String? path]) => DynamicLibrary.open(
    path ?? Platform.environment[libraryPathVariable] ?? libraryName,
  );
}
