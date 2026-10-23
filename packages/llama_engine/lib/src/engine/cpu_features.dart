import 'dart:ffi';
import 'dart:io';

import 'package:meta/meta.dart';

/// The optional ARMv8 instructions an arm64 CPU has, from `/proc/cpuinfo`:
/// they decide which build of the native engine runs fastest without
/// crashing (an instruction the CPU lacks is a SIGILL).
@immutable
final class ArmCpuFeatures {
  const new({
    this.dotprod = false,
    this.fp16 = false,
    this.i8mm = false,
    this.sve = false,
  });

  /// Parses the `Features` lines of `/proc/cpuinfo`. A feature counts only
  /// if every core lists it: big.LITTLE phones can differ between cores,
  /// and a thread may run on any of them. Linux names: dotprod = `asimddp`,
  /// fp16 = `asimdhp` and `fphp`, i8mm = `i8mm`, sve = `sve`. Without any
  /// `Features` line nothing counts.
  factory parse(String cpuinfo) {
    Set<String>? common;
    for (final line in cpuinfo.split('\n')) {
      final separator = line.indexOf(':');
      if (separator < 0) continue;
      if (line.substring(0, separator).trim().toLowerCase() != 'features') {
        continue;
      }
      final features = line
          .substring(separator + 1)
          .trim()
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((feature) => feature.isNotEmpty)
          .toSet();
      common = common == null ? features : common.intersection(features);
    }
    final found = common ?? const <String>{};
    return ArmCpuFeatures(
      dotprod: found.contains('asimddp'),
      fp16: found.contains('asimdhp') && found.contains('fphp'),
      i8mm: found.contains('i8mm'),
      sve: found.contains('sve'),
    );
  }

  /// The CPU's features on Android arm64; null elsewhere or when
  /// `/proc/cpuinfo` cannot be read.
  static ArmCpuFeatures? current() {
    try {
      if (!Platform.isAndroid || Abi.current() != Abi.androidArm64) {
        return null;
      }
      return ArmCpuFeatures.parse(File('/proc/cpuinfo').readAsStringSync());
    } on Object {
      return null;
    }
  }

  /// SDOT/UDOT (ARMv8.2 dot product; Linux `asimddp`).
  final bool dotprod;

  /// Half-precision arithmetic (ARMv8.2 FP16; `asimdhp` and `fphp`).
  final bool fp16;

  /// Int8 matrix multiplication (ARMv8.6 I8MM; `i8mm`).
  final bool i8mm;

  /// Scalable vectors (`sve`); no library variant uses it yet.
  final bool sve;

  @override
  bool operator ==(Object other) =>
      other is ArmCpuFeatures &&
      other.dotprod == dotprod &&
      other.fp16 == fp16 &&
      other.i8mm == i8mm &&
      other.sve == sve;

  @override
  int get hashCode => Object.hash(dotprod, fp16, i8mm, sve);

  @override
  String toString() =>
      'ArmCpuFeatures(dotprod: $dotprod, fp16: $fp16, i8mm: $i8mm, '
      'sve: $sve)';
}
