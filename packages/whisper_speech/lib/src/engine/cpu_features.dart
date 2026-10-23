import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io' show File, Platform;

import 'package:meta/meta.dart';

/// The ARM CPU features that faster builds of the native engine use, as
/// the Linux kernel reports them in `/proc/cpuinfo` (contract §4; the same
/// class as in `packages/llama_engine`).
///
/// A feature counts only if every core lists it: on big.LITTLE phones the
/// cores can differ (an Exynos 9810's Mongoose cores lack the dot product
/// its Cortex-A55 cores have), and a thread may run on any of them.
@immutable
final class ArmCpuFeatures {
  const new({
    this.dotprod = false,
    this.fp16 = false,
    this.i8mm = false,
    this.sve = false,
  });

  /// Parses the `Features` lines of `/proc/cpuinfo` (one per core, or one
  /// for all on old kernels). Text without any (x86, an empty file) has no
  /// features.
  factory parse(String cpuinfo) {
    Set<String>? common;
    for (final line in const LineSplitter().convert(cpuinfo)) {
      final colon = line.indexOf(':');
      if (colon < 0 ||
          line.substring(0, colon).trim().toLowerCase() != 'features') {
        continue;
      }
      final features = {
        for (final name in line.substring(colon + 1).trim().split(_spaces))
          if (name.isNotEmpty) name.toLowerCase(),
      };
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

  /// The features of this device's CPU: null when not on Android arm64
  /// (nothing to choose there) or when `/proc/cpuinfo` cannot be read.
  /// Read once.
  static ArmCpuFeatures? current() => (_current ??= (
    read(
      isAndroidArm64: Platform.isAndroid && Abi.current() == Abi.androidArm64,
      cpuinfo: () => File('/proc/cpuinfo').readAsStringSync(),
    ),
  )).$1;

  static (ArmCpuFeatures?,)? _current;

  /// [current] for [isAndroidArm64] with [cpuinfo] as `/proc/cpuinfo`
  /// (tests).
  @visibleForTesting
  static ArmCpuFeatures? read({
    required bool isAndroidArm64,
    required String Function() cpuinfo,
  }) {
    if (!isAndroidArm64) return null;
    try {
      return ArmCpuFeatures.parse(cpuinfo());
    } on Object {
      return null;
    }
  }

  /// SDOT/UDOT, the int8 dot product (`asimddp`; ARMv8.2-A, mandatory from
  /// ARMv8.4-A): the quantized kernels' main speed-up.
  final bool dotprod;

  /// Half-precision arithmetic (`asimdhp` and `fphp`; ARMv8.2-A): the F16
  /// models' matrix products.
  final bool fp16;

  /// Int8 matrix multiply (`i8mm`; ARMv8.6-A, every ARMv9 core).
  final bool i8mm;

  /// The scalable vector extension (`sve`); not used by the builds yet.
  final bool sve;

  static final _spaces = RegExp(r'\s+');

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
