import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llama_engine/src/engine/cpu_features.dart';
import 'package:llama_engine/src/engine/cpu_variant_guard.dart';
import 'package:llama_engine/src/engine/engine_factory_ffi.dart' as ffi;
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('llama_build_'));
  tearDown(() => root.deleteSync(recursive: true));

  const v9 = ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true);
  const v82 = ArmCpuFeatures(dotprod: true, fp16: true);

  LlamaEngineBuild build(ArmCpuFeatures? features, {String? path}) =>
      ffi.llamaEngineBuild(
        libraryPath: path,
        variantGuardDirectory: root.path,
        cpuFeatures: () => features,
        environment: const {},
      );

  void skip(Set<String> libraries) => File(
    p.join(root.path, 'llama_cpu_variants.json'),
  ).writeAsStringSync(jsonEncode(CpuVariantState(skipped: libraries).toJson()));

  test('names the fastest build for the processor', () {
    expect(build(v9).variant, LlamaCpuVariant.i8mm);
    expect(build(v9).library, 'libmozhi_llama_i8mm.so');
    expect(build(v82).variant, LlamaCpuVariant.dotprod);
    expect(build(null).variant, LlamaCpuVariant.baseline);
    expect(build(null).skipped, isEmpty);
    expect(build(v9, path: '/x/lib.so').variant, LlamaCpuVariant.custom);
  });

  test('falls back past the builds the guard turned off', () {
    skip({'libmozhi_llama_i8mm.so'});
    expect(build(v9).variant, LlamaCpuVariant.baseline);
    expect(build(v9).skipped, [LlamaCpuVariant.i8mm]);
    skip({'libmozhi_llama_i8mm.so', 'libmozhi_llama_dotprod.so'});
    expect(build(v82).skipped, [LlamaCpuVariant.i8mm, LlamaCpuVariant.dotprod]);
  });

  test('works without a guard', () {
    expect(
      ffi
          .llamaEngineBuild(cpuFeatures: () => v82, environment: const {})
          .variant,
      LlamaCpuVariant.dotprod,
    );
  });

  test('compares by value', () {
    const a = LlamaEngineBuild(
      variant: LlamaCpuVariant.baseline,
      library: 'x',
      skipped: [LlamaCpuVariant.i8mm],
    );
    expect(
      a,
      const LlamaEngineBuild(
        variant: LlamaCpuVariant.baseline,
        library: 'x',
        skipped: [LlamaCpuVariant.i8mm],
      ),
    );
    expect(a.hashCode, isA<int>());
    expect(
      a,
      isNot(
        const LlamaEngineBuild(variant: LlamaCpuVariant.baseline, library: 'x'),
      ),
    );
    expect(
      a,
      isNot(
        const LlamaEngineBuild(
          variant: LlamaCpuVariant.baseline,
          library: 'x',
          skipped: [LlamaCpuVariant.dotprod],
        ),
      ),
    );
    expect(a.toString(), contains('i8mm'));
  });

  test('the guard of the app guards the faster builds', () {
    final guard = ffi.llamaVariantGuard(root.path);
    expect(guard.variants, {
      'libmozhi_llama_dotprod.so',
      'libmozhi_llama_i8mm.so',
    });
    expect(
      ffi.createLlamaEngine(variantGuardDirectory: root.path),
      isA<LlamaEngine>(),
    );
  });
}
