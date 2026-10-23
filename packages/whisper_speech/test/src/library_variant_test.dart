import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/src/engine/cpu_features.dart';
import 'package:whisper_speech/src/engine/ffi/bindings.dart';

const _dotprod = ArmCpuFeatures(dotprod: true, fp16: true);
const _i8mm = ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true);

/// A fake loader: the ABI version of each library that opens; the others
/// throw like `DynamicLibrary.open`.
class _Loader {
  new(this.abis);

  final Map<String, int> abis;
  final opened = <String>[];

  int call(String library) {
    opened.add(library);
    return abis[library] ??
        (throw ArgumentError('dlopen failed: library "$library" not found'));
  }
}

void main() {
  group('WhisperLibraryVariant', () {
    test('names the libraries of native/CMakeLists.txt', () {
      expect(WhisperLibraryVariant.values.map((v) => v.fileName), [
        'libmozhi_whisper.so',
        'libmozhi_whisper_dotprod.so',
        'libmozhi_whisper_i8mm.so',
      ]);
      expect(
        WhisperLibraryVariant.baseline.fileName,
        WhisperBindings.libraryName,
      );
    });

    test('picks the fastest one the CPU runs (contract §4)', () {
      expect(
        WhisperLibraryVariant.forCpu(null),
        WhisperLibraryVariant.baseline,
      );
      expect(
        WhisperLibraryVariant.forCpu(const ArmCpuFeatures()),
        WhisperLibraryVariant.baseline,
      );
      expect(
        WhisperLibraryVariant.forCpu(const ArmCpuFeatures(dotprod: true)),
        WhisperLibraryVariant.baseline,
      );
      expect(
        WhisperLibraryVariant.forCpu(const ArmCpuFeatures(fp16: true)),
        WhisperLibraryVariant.baseline,
      );
      expect(
        WhisperLibraryVariant.forCpu(
          const ArmCpuFeatures(fp16: true, i8mm: true, sve: true),
        ),
        WhisperLibraryVariant.baseline,
      );
      expect(
        WhisperLibraryVariant.forCpu(_dotprod),
        WhisperLibraryVariant.dotprod,
      );
      expect(
        WhisperLibraryVariant.forCpu(
          const ArmCpuFeatures(dotprod: true, fp16: true, sve: true),
        ),
        WhisperLibraryVariant.dotprod,
      );
      expect(WhisperLibraryVariant.forCpu(_i8mm), WhisperLibraryVariant.i8mm);
    });
  });

  group('WhisperBindings.resolve', () {
    test('an explicit path or WHISPER_LIBRARY_PATH wins', () {
      final loader = _Loader({});
      expect(
        WhisperBindings.resolve(
          path: '/x/libmozhi_whisper.so',
          environment: {'WHISPER_LIBRARY_PATH': '/y/lib.so'},
          cpuFeatures: () => _i8mm,
          probe: loader.call,
        ),
        '/x/libmozhi_whisper.so',
      );
      expect(
        WhisperBindings.resolve(
          environment: {'WHISPER_LIBRARY_PATH': '/y/lib.so'},
          cpuFeatures: () => _i8mm,
          probe: loader.call,
        ),
        '/y/lib.so',
      );
      expect(loader.opened, isEmpty);
    });

    test('the baseline without CPU features, without opening it', () {
      final loader = _Loader({});
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => null,
          probe: loader.call,
        ),
        'libmozhi_whisper.so',
      );
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => const ArmCpuFeatures(),
          probe: loader.call,
        ),
        'libmozhi_whisper.so',
      );
      // Its errors are reported when the engine opens it.
      expect(loader.opened, isEmpty);
    });

    test('the variant for the CPU when it opens with the ABI', () {
      const abi = WhisperBindings.expectedAbiVersion;
      final loader = _Loader({
        'libmozhi_whisper.so': abi,
        'libmozhi_whisper_dotprod.so': abi,
        'libmozhi_whisper_i8mm.so': abi,
      });
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => _dotprod,
          probe: loader.call,
        ),
        'libmozhi_whisper_dotprod.so',
      );
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => _i8mm,
          probe: loader.call,
        ),
        'libmozhi_whisper_i8mm.so',
      );
      expect(loader.opened, [
        'libmozhi_whisper_dotprod.so',
        'libmozhi_whisper_i8mm.so',
      ]);
    });

    test('falls back to the baseline when the variant does not open', () {
      final loader = _Loader({
        'libmozhi_whisper.so': WhisperBindings.expectedAbiVersion,
      });
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => _i8mm,
          probe: loader.call,
        ),
        'libmozhi_whisper.so',
      );
      // Straight to the baseline, not the dotprod build (contract §4).
      expect(loader.opened, ['libmozhi_whisper_i8mm.so']);
    });

    test('falls back to the baseline when the ABI differs', () {
      final loader = _Loader({
        'libmozhi_whisper_dotprod.so': WhisperBindings.expectedAbiVersion + 1,
      });
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => _dotprod,
          probe: loader.call,
        ),
        'libmozhi_whisper.so',
      );
    });

    test('reads the CPU and opens the variant by default', () {
      // Not Android arm64 here: the baseline, from the process environment
      // (WHISPER_LIBRARY_PATH when the native tests set it).
      expect(
        WhisperBindings.resolve(),
        anyOf('libmozhi_whisper.so', endsWith('.so')),
      );
      // The real loader: a variant that is not on the search path.
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => _i8mm,
        ),
        'libmozhi_whisper.so',
      );
    });
  });
}
