import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/engine/cpu_features.dart';
import 'package:whisper_speech/src/engine/cpu_variant_guard.dart';
import 'package:whisper_speech/src/engine/engine_factory_ffi.dart' as ffi;
import 'package:whisper_speech/src/engine/engine_factory_stub.dart' as stub;
import 'package:whisper_speech/src/engine/ffi/bindings.dart';
import 'package:whisper_speech/whisper_speech.dart'
    show WhisperCpuVariant, WhisperEngine, WhisperEngineBuild, WhisperVadEngine;

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

  group('WhisperBindings.resolve with a guard', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('whisper_res_'));
    tearDown(() => root.deleteSync(recursive: true));

    CpuVariantGuard guard(int processId) => CpuVariantGuard(
      directory: root.path,
      variants: const {
        'libmozhi_whisper_dotprod.so',
        'libmozhi_whisper_i8mm.so',
      },
      processId: processId,
    );

    File marker(String role) =>
        File(p.join(root.path, 'whisper_cpu_variant.$role.marker'));

    test('writes a marker while it probes, removed afterwards', () {
      var markedWhileProbing = false;
      final library = WhisperBindings.resolve(
        environment: const {},
        cpuFeatures: () => _i8mm,
        probe: (library) {
          markedWhileProbing = marker('open-vad').existsSync();
          return WhisperBindings.expectedAbiVersion;
        },
        guard: guard(1),
        role: 'open-vad',
      );
      expect(library, 'libmozhi_whisper_i8mm.so');
      expect(markedWhileProbing, isTrue);
      expect(marker('open-vad').existsSync(), isFalse);
    });

    test('a variant that crashed while probed is not probed again', () {
      // The probe "crashed" the process: the marker stays behind.
      guard(1).arm('libmozhi_whisper_i8mm.so', role: 'open');
      final loader = _Loader({
        'libmozhi_whisper_i8mm.so': WhisperBindings.expectedAbiVersion,
      });
      expect(
        WhisperBindings.resolve(
          environment: const {},
          cpuFeatures: () => _i8mm,
          probe: loader.call,
          guard: guard(2),
        ),
        'libmozhi_whisper.so',
      );
      expect(loader.opened, isEmpty);
      expect(guard(3).read().skipped, {'libmozhi_whisper_i8mm.so'});
    });

    test('an explicit library is never guarded', () {
      expect(
        WhisperBindings.resolve(
          path: '/x/lib.so',
          cpuFeatures: () => _i8mm,
          guard: guard(1),
        ),
        '/x/lib.so',
      );
      expect(root.listSync(), isEmpty);
    });
  });

  group('whisperEngineBuild', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('whisper_build_'));
    tearDown(() => root.deleteSync(recursive: true));

    WhisperEngineBuild build(
      ArmCpuFeatures? features, {
      String? path,
      Map<String, String> environment = const {},
    }) => ffi.whisperEngineBuild(
      libraryPath: path,
      variantGuardDirectory: root.path,
      cpuFeatures: () => features,
      environment: environment,
    );

    test('names the fastest build for the processor', () {
      expect(build(_i8mm).variant, WhisperCpuVariant.i8mm);
      expect(build(_i8mm).library, 'libmozhi_whisper_i8mm.so');
      expect(build(_dotprod).variant, WhisperCpuVariant.dotprod);
      expect(build(null).variant, WhisperCpuVariant.baseline);
      expect(build(_i8mm, path: '/x.so').variant, WhisperCpuVariant.custom);
      expect(
        build(_i8mm, environment: {'WHISPER_LIBRARY_PATH': '/y.so'}).library,
        '/y.so',
      );
    });

    test('the baseline once the guard turned a build off', () {
      File(p.join(root.path, 'whisper_cpu_variants.json')).writeAsStringSync(
        jsonEncode(
          const CpuVariantState(skipped: {'libmozhi_whisper_i8mm.so'}).toJson(),
        ),
      );
      expect(build(_i8mm).variant, WhisperCpuVariant.baseline);
      expect(build(_i8mm).skipped, [WhisperCpuVariant.i8mm]);
      // The dotprod build still runs where it is the fastest.
      expect(build(_dotprod).variant, WhisperCpuVariant.dotprod);
    });

    test('works without a guard, and compares by value', () {
      final plain = ffi.whisperEngineBuild(
        cpuFeatures: () => _dotprod,
        environment: const {},
      );
      expect(
        plain,
        const WhisperEngineBuild(
          variant: WhisperCpuVariant.dotprod,
          library: 'libmozhi_whisper_dotprod.so',
        ),
      );
      expect(plain.hashCode, isA<int>());
      expect(
        plain,
        isNot(
          const WhisperEngineBuild(
            variant: WhisperCpuVariant.dotprod,
            library: 'libmozhi_whisper_dotprod.so',
            skipped: [WhisperCpuVariant.i8mm],
          ),
        ),
      );
      expect(plain.toString(), contains('dotprod'));
      expect(ffi.whisperVariantGuard(root.path).variants, hasLength(2));
      expect(
        ffi.createWhisperEngine(variantGuardDirectory: root.path),
        isA<WhisperEngine>(),
      );
      expect(
        ffi.createWhisperVadEngine(variantGuardDirectory: root.path),
        isA<WhisperVadEngine>(),
      );
      expect(stub.whisperEngineBuild().variant, WhisperCpuVariant.baseline);
      expect(
        stub.createWhisperEngine(variantGuardDirectory: root.path),
        isA<WhisperEngine>(),
      );
      expect(
        stub.createWhisperVadEngine(variantGuardDirectory: root.path),
        isA<WhisperVadEngine>(),
      );
    });
  });
}
