import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/engine/cpu_features.dart';
import 'package:whisper_speech/src/engine/ffi/bindings.dart';

/// `/proc/cpuinfo` of a device (`test/fixtures/cpuinfo/<name>.txt`): the
/// kernel's format with the cores and feature lists those chips report.
String cpuinfo(String name) =>
    File(p.join('test', 'fixtures', 'cpuinfo', '$name.txt')).readAsStringSync();

void main() {
  group('ArmCpuFeatures.parse', () {
    test('Snapdragon 888: dotprod and FP16, no i8mm', () {
      final features = ArmCpuFeatures.parse(cpuinfo('snapdragon_888'));
      expect(features, const ArmCpuFeatures(dotprod: true, fp16: true));
      expect(
        WhisperLibraryVariant.forCpu(features),
        WhisperLibraryVariant.dotprod,
      );
    });

    test('Snapdragon 8 Gen 2: i8mm, SVE disabled', () {
      final features = ArmCpuFeatures.parse(cpuinfo('snapdragon_8_gen_2'));
      expect(
        features,
        const ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true),
      );
      expect(
        WhisperLibraryVariant.forCpu(features),
        WhisperLibraryVariant.i8mm,
      );
    });

    test('Tensor G3: i8mm and SVE', () {
      final features = ArmCpuFeatures.parse(cpuinfo('tensor_g3'));
      expect(
        features,
        const ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true, sve: true),
      );
      expect(
        WhisperLibraryVariant.forCpu(features),
        WhisperLibraryVariant.i8mm,
      );
    });

    test('an old Cortex-A53 phone (one Features line): none', () {
      final features = ArmCpuFeatures.parse(cpuinfo('cortex_a53'));
      expect(features, const ArmCpuFeatures());
      expect(
        WhisperLibraryVariant.forCpu(features),
        WhisperLibraryVariant.baseline,
      );
    });

    test('big.LITTLE with different cores: only what every core has', () {
      // Exynos 9810: its Cortex-A55 cores have dotprod and FP16, its
      // Mongoose M3 cores do not.
      final text = cpuinfo('exynos_9810');
      expect(text, contains('asimddp'));
      final features = ArmCpuFeatures.parse(text);
      expect(features, const ArmCpuFeatures());
      expect(
        WhisperLibraryVariant.forCpu(features),
        WhisperLibraryVariant.baseline,
      );
    });

    test('a feature missing on one core only drops that feature', () {
      final features = ArmCpuFeatures.parse(
        'processor\t: 0\n'
        'Features\t: fp asimd fphp asimdhp asimddp i8mm sve\n'
        '\n'
        'processor\t: 1\n'
        'Features\t: fp asimd fphp asimdhp i8mm\n',
      );
      expect(features, const ArmCpuFeatures(fp16: true, i8mm: true));
      // i8mm without dotprod: the i8mm build would not run.
      expect(
        WhisperLibraryVariant.forCpu(features),
        WhisperLibraryVariant.baseline,
      );
    });

    test('FP16 needs both asimdhp and fphp', () {
      expect(
        ArmCpuFeatures.parse('Features: fp asimd asimdhp asimddp').fp16,
        isFalse,
      );
      expect(
        ArmCpuFeatures.parse('Features: fp asimd fphp asimddp').fp16,
        isFalse,
      );
      expect(
        ArmCpuFeatures.parse('FEATURES  :  FPHP   ASIMDHP\tASIMDDP').fp16,
        isTrue,
      );
    });

    test('an x86_64 emulator or no Features lines: none', () {
      expect(
        ArmCpuFeatures.parse(cpuinfo('x86_64_emulator')),
        const ArmCpuFeatures(),
      );
      expect(ArmCpuFeatures.parse(''), const ArmCpuFeatures());
      expect(
        ArmCpuFeatures.parse('no colon here\nfeatures-ish: asimddp'),
        const ArmCpuFeatures(),
      );
    });
  });

  group('ArmCpuFeatures.current', () {
    test('is null off Android arm64 (these tests)', () {
      expect(ArmCpuFeatures.current(), isNull);
      // Read once.
      expect(ArmCpuFeatures.current(), isNull);
    });

    test('reads /proc/cpuinfo on Android arm64', () {
      expect(
        ArmCpuFeatures.read(
          isAndroidArm64: true,
          cpuinfo: () => cpuinfo('snapdragon_888'),
        ),
        const ArmCpuFeatures(dotprod: true, fp16: true),
      );
      expect(
        ArmCpuFeatures.read(
          isAndroidArm64: false,
          cpuinfo: () => fail('not read'),
        ),
        isNull,
      );
    });

    test('is null when /proc/cpuinfo cannot be read', () {
      expect(
        ArmCpuFeatures.read(
          isAndroidArm64: true,
          cpuinfo: () => throw const FileSystemException('denied'),
        ),
        isNull,
      );
    });
  });

  test('describes itself and compares by value', () {
    expect(
      const ArmCpuFeatures().toString(),
      'ArmCpuFeatures(dotprod: false, fp16: false, i8mm: false, sve: false)',
    );
    expect(
      const ArmCpuFeatures(
        dotprod: true,
        fp16: true,
        i8mm: true,
        sve: true,
      ).toString(),
      'ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true, sve: true)',
    );
    expect(
      const ArmCpuFeatures(dotprod: true).hashCode,
      const ArmCpuFeatures(dotprod: true).hashCode,
    );
    expect(
      const ArmCpuFeatures(dotprod: true),
      isNot(const ArmCpuFeatures(fp16: true)),
    );
  });
}
