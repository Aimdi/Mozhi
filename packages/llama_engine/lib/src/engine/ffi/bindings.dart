// Hand-written bindings for native/src/mozhi_llama.h (keep in sync; the
// library reports MOZHI_LLAMA_ABI_VERSION, checked on load).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llama_engine/src/engine/cpu_features.dart';

/// Opaque `MozhiLlamaModel`.
final class NativeLlamaModel extends Opaque;

/// `MozhiLlamaParams`.
final class NativeLlamaParams extends Struct {
  @Float()
  external double temperature;

  @Int32()
  external int topK;

  @Float()
  external double topP;

  @Float()
  external double minP;

  @Float()
  external double repeatPenalty;

  @Int32()
  external int repeatLastN;

  @Uint32()
  external int seed;

  @Int32()
  external int maxTokens;

  external Pointer<Utf8> grammar;

  external Pointer<Pointer<Utf8>> stop;

  @Int32()
  external int stopCount;

  external Pointer<Int32> cancelFlag;
}

/// `MozhiLlamaStats`.
final class NativeLlamaStats extends Struct {
  @Int32()
  external int promptTokens;

  @Int32()
  external int generatedTokens;

  @Int32()
  external int finishReason;

  @Int32()
  external int reserved;

  @Double()
  external double promptMs;

  @Double()
  external double generateMs;
}

typedef _ModelLoadNative = Pointer<NativeLlamaModel> Function(
  Pointer<Utf8>,
  Int32,
  Int32,
  Int32,
);
typedef _ModelLoad = Pointer<NativeLlamaModel> Function(
  Pointer<Utf8>,
  int,
  int,
  int,
);
typedef _ChatFormatNative = Pointer<Utf8> Function(
  Pointer<NativeLlamaModel>,
  Pointer<Pointer<Utf8>>,
  Pointer<Pointer<Utf8>>,
  Int32,
  Int32,
);

/// `mozhi_llama_chat_format`.
typedef ChatFormatFunction = Pointer<Utf8> Function(
  Pointer<NativeLlamaModel> model,
  Pointer<Pointer<Utf8>> roles,
  Pointer<Pointer<Utf8>> contents,
  int count,
  int addAssistant,
);

/// The functions of `libmozhi_llama`.
final class LlamaBindings {
  new(DynamicLibrary library)
    : abiVersion = library.lookupFunction<Int32 Function(), int Function()>(
        'mozhi_llama_abi_version',
      ),
      version = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_llama_version',
          ),
      cpuFeatures = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_llama_cpu_features',
          ),
      jsonGrammar = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_llama_json_grammar',
          ),
      modelLoad = library.lookupFunction<_ModelLoadNative, _ModelLoad>(
        'mozhi_llama_model_load',
      ),
      modelFree = library
          .lookupFunction<
            Void Function(Pointer<NativeLlamaModel>),
            void Function(Pointer<NativeLlamaModel>)
          >('mozhi_llama_model_free'),
      modelInfo = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<NativeLlamaModel>),
            Pointer<Utf8> Function(Pointer<NativeLlamaModel>)
          >('mozhi_llama_model_info'),
      chatFormat = library
          .lookupFunction<_ChatFormatNative, ChatFormatFunction>(
            'mozhi_llama_chat_format',
          ),
      tokenizeCount = library
          .lookupFunction<
            Int32 Function(Pointer<NativeLlamaModel>, Pointer<Utf8>),
            int Function(Pointer<NativeLlamaModel>, Pointer<Utf8>)
          >('mozhi_llama_tokenize_count'),
      generateBegin = library
          .lookupFunction<
            Int32 Function(
              Pointer<NativeLlamaModel>,
              Pointer<Utf8>,
              Pointer<NativeLlamaParams>,
            ),
            int Function(
              Pointer<NativeLlamaModel>,
              Pointer<Utf8>,
              Pointer<NativeLlamaParams>,
            )
          >('mozhi_llama_generate_begin'),
      generateNext = library
          .lookupFunction<
            Int32 Function(Pointer<NativeLlamaModel>, Pointer<Utf8>, Int32),
            int Function(Pointer<NativeLlamaModel>, Pointer<Utf8>, int)
          >('mozhi_llama_generate_next'),
      generateEnd = library
          .lookupFunction<
            Void Function(Pointer<NativeLlamaModel>),
            void Function(Pointer<NativeLlamaModel>)
          >('mozhi_llama_generate_end'),
      generateStats = library
          .lookupFunction<
            Int32 Function(
              Pointer<NativeLlamaModel>,
              Pointer<NativeLlamaStats>,
            ),
            int Function(Pointer<NativeLlamaModel>, Pointer<NativeLlamaStats>)
          >('mozhi_llama_generate_stats'),
      cancel = library.lookupFunction<Void Function(), void Function()>(
        'mozhi_llama_cancel',
      ),
      freeString = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('mozhi_llama_free_string'),
      lastError = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'mozhi_llama_last_error',
          );

  /// MOZHI_LLAMA_ABI_VERSION these bindings were written for.
  static const expectedAbiVersion = 1;

  /// File name of the baseline library (Android packs it into the APK per
  /// ABI; arm64-v8a also has [dotprodLibraryName] and [i8mmLibraryName]).
  static const libraryName = 'libmozhi_llama.so';

  /// ARMv8.2-A + dotprod + fp16 (arm64 only).
  static const dotprodLibraryName = 'libmozhi_llama_dotprod.so';

  /// ARMv8.6-A + dotprod + fp16 + i8mm (arm64 only).
  static const i8mmLibraryName = 'libmozhi_llama_i8mm.so';

  /// Environment variable with an explicit library path (desktop tests).
  static const libraryPathVariable = 'LLAMA_LIBRARY_PATH';

  /// Bytes of the buffer for one piece of generated text.
  static const pieceBufferSize = 4096;

  /// `MOZHI_LLAMA_OK`, `_E_ERROR`, `_E_CANCELLED`, `_E_CONTEXT`.
  static const ok = 0;
  static const error = -1;
  static const cancelled = -2;
  static const contextFull = -3;

  /// `MOZHI_LLAMA_FINISH_STOP`, `_LENGTH`.
  static const finishStop = 1;
  static const finishLength = 2;

  /// `MOZHI_LLAMA_RANDOM_SEED`.
  static const randomSeed = 0xFFFFFFFF;

  final int Function() abiVersion;
  final Pointer<Utf8> Function() version;
  final Pointer<Utf8> Function() cpuFeatures;
  final Pointer<Utf8> Function() jsonGrammar;
  final Pointer<NativeLlamaModel> Function(
    Pointer<Utf8> path,
    int threads,
    int contextSize,
    int useMmap,
  )
  modelLoad;
  final void Function(Pointer<NativeLlamaModel> model) modelFree;
  final Pointer<Utf8> Function(Pointer<NativeLlamaModel> model) modelInfo;
  final ChatFormatFunction chatFormat;
  final int Function(Pointer<NativeLlamaModel> model, Pointer<Utf8> text)
  tokenizeCount;
  final int Function(
    Pointer<NativeLlamaModel> model,
    Pointer<Utf8> prompt,
    Pointer<NativeLlamaParams> params,
  )
  generateBegin;
  final int Function(
    Pointer<NativeLlamaModel> model,
    Pointer<Utf8> buffer,
    int size,
  )
  generateNext;
  final void Function(Pointer<NativeLlamaModel> model) generateEnd;
  final int Function(
    Pointer<NativeLlamaModel> model,
    Pointer<NativeLlamaStats> stats,
  )
  generateStats;
  final void Function() cancel;
  final void Function(Pointer<Utf8> text) freeString;
  final Pointer<Utf8> Function() lastError;

  /// The libraries to try, best first: [path] or `$LLAMA_LIBRARY_PATH`
  /// alone when given, else the fastest variant [features] allow (contract:
  /// i8mm + dotprod + fp16 → `_i8mm`, dotprod + fp16 → `_dotprod`) and then
  /// the baseline, which every CPU runs.
  static List<String> candidates({
    String? path,
    ArmCpuFeatures? features,
    Map<String, String>? environment,
  }) {
    final explicit =
        path ?? (environment ?? Platform.environment)[libraryPathVariable];
    if (explicit != null && explicit.isNotEmpty) return [explicit];
    final fast = features != null && features.dotprod && features.fp16;
    return [
      if (fast && features.i8mm)
        i8mmLibraryName
      else if (fast)
        dotprodLibraryName,
      libraryName,
    ];
  }

  /// Opens a library by path or name (from the APK on Android).
  static DynamicLibrary open(String path) => DynamicLibrary.open(path);
}
