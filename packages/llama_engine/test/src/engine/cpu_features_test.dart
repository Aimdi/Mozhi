import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/src/engine/cpu_features.dart';
import 'package:llama_engine/src/engine/ffi/bindings.dart';

/// `/proc/cpuinfo` of an arm64 phone: one block per core with [features].
String cpuinfo(List<String> features, {String hardware = 'Test SoC'}) {
  final buffer = StringBuffer();
  for (var core = 0; core < features.length; core++) {
    buffer
      ..writeln('processor\t: $core')
      ..writeln('BogoMIPS\t: 38.40')
      ..writeln('Features\t: ${features[core]}')
      ..writeln('CPU implementer\t: 0x41')
      ..writeln('CPU architecture: 8')
      ..writeln('CPU variant\t: 0x1')
      ..writeln('CPU part\t: 0xd05')
      ..writeln('CPU revision\t: 0')
      ..writeln();
  }
  buffer.writeln('Hardware\t: $hardware');
  return buffer.toString();
}

// Kryo 680 (Cortex-X1, A78, A55; ARMv8.2): dot product and FP16, no I8MM.
const snapdragon888 =
    'fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid '
    'asimdrdm lrcpc dcpop asimddp';

// Cortex-X3, A715, A510 (ARMv9.0) as Linux reports them on a Tensor G3 /
// Snapdragon 8 Gen 2: I8MM and BF16 too (SVE is not exposed).
const tensorG3 =
    'fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid '
    'asimdrdm jscvt fcma lrcpc dcpop sha3 sm3 sm4 asimddp sha512 asimdfhm '
    'dit uscat ilrcpc flagm ssbs sb paca pacg dcpodp flagm2 frint i8mm bf16 '
    'dgh bti mte ecv afp mte3';

// A server-class core with SVE (and SVE's own int8 matrix feature).
const neoverseV1 =
    'fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid '
    'asimdrdm jscvt fcma lrcpc dcpop sha3 sm3 sm4 asimddp sha512 sve '
    'asimdfhm dit uscat ilrcpc flagm ssbs paca pacg dcpodp svei8mm svebf16 '
    'i8mm bf16 dgh rng';

// Cortex-A53 (ARMv8.0, e.g. a Snapdragon 425 phone): none of them.
const cortexA53 = 'fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid';

// An x86_64 emulator: "flags", no "Features".
const x86Emulator = '''
processor	: 0
vendor_id	: GenuineIntel
model name	: Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov sse sse2 ssse3 sse4_1 sse4_2 avx avx2
''';

void main() {
  group('ArmCpuFeatures.parse', () {
    test('Snapdragon 888: dot product and FP16', () {
      final features = ArmCpuFeatures.parse(
        cpuinfo(List.filled(8, snapdragon888), hardware: 'SM8350'),
      );
      expect(features, const ArmCpuFeatures(dotprod: true, fp16: true));
      expect(LlamaBindings.candidates(features: features, environment: {}), [
        LlamaBindings.dotprodLibraryName,
        LlamaBindings.libraryName,
      ]);
    });

    test('Tensor G3 / Snapdragon 8 Gen 2: I8MM as well', () {
      final features = ArmCpuFeatures.parse(cpuinfo(List.filled(9, tensorG3)));
      expect(
        features,
        const ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true),
      );
      expect(LlamaBindings.candidates(features: features, environment: {}), [
        LlamaBindings.i8mmLibraryName,
        LlamaBindings.libraryName,
      ]);
    });

    test('SVE counts; svei8mm is not i8mm', () {
      expect(
        ArmCpuFeatures.parse(cpuinfo([neoverseV1])),
        const ArmCpuFeatures(dotprod: true, fp16: true, i8mm: true, sve: true),
      );
      expect(
        ArmCpuFeatures.parse(cpuinfo(['$cortexA53 svei8mm svebf16'])).i8mm,
        isFalse,
      );
    });

    test('Cortex-A53: the baseline', () {
      final features = ArmCpuFeatures.parse(cpuinfo(List.filled(4, cortexA53)));
      expect(features, const ArmCpuFeatures());
      expect(LlamaBindings.candidates(features: features, environment: {}), [
        LlamaBindings.libraryName,
      ]);
    });

    test('big.LITTLE: a feature only counts if every core has it', () {
      final mixed = cpuinfo([
        ...List.filled(4, tensorG3),
        ...List.filled(4, snapdragon888),
      ]);
      expect(
        ArmCpuFeatures.parse(mixed),
        const ArmCpuFeatures(dotprod: true, fp16: true),
      );
      final noDotprod = cpuinfo([...List.filled(4, snapdragon888), cortexA53]);
      expect(ArmCpuFeatures.parse(noDotprod), const ArmCpuFeatures());
    });

    test('FP16 needs both asimdhp and fphp', () {
      expect(ArmCpuFeatures.parse(cpuinfo(['fp asimd asimdhp'])).fp16, isFalse);
      expect(
        ArmCpuFeatures.parse(cpuinfo(['fp asimd asimdhp fphp'])).fp16,
        isTrue,
      );
    });

    test('dot product without FP16 runs the baseline', () {
      final features = ArmCpuFeatures.parse(cpuinfo(['fp asimd asimddp i8mm']));
      expect(features.dotprod, isTrue);
      expect(features.fp16, isFalse);
      expect(LlamaBindings.candidates(features: features, environment: {}), [
        LlamaBindings.libraryName,
      ]);
    });

    test('an x86_64 emulator, an empty file and odd spacing', () {
      expect(ArmCpuFeatures.parse(x86Emulator), const ArmCpuFeatures());
      expect(ArmCpuFeatures.parse(''), const ArmCpuFeatures());
      expect(
        ArmCpuFeatures.parse('FEATURES :  fp   ASIMDDP asimdhp fphp\r\n'),
        const ArmCpuFeatures(dotprod: true, fp16: true),
      );
    });

    test('equality and description', () {
      const features = ArmCpuFeatures(dotprod: true);
      expect(features, const ArmCpuFeatures(dotprod: true));
      expect(features.hashCode, const ArmCpuFeatures(dotprod: true).hashCode);
      expect(features, isNot(const ArmCpuFeatures()));
      expect(
        features.toString(),
        'ArmCpuFeatures(dotprod: true, fp16: false, i8mm: false, sve: false)',
      );
    });
  });

  test('current() is null off Android', () {
    expect(ArmCpuFeatures.current(), isNull);
  });
}
