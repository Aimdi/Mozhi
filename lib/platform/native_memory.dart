import 'dart:async';
import 'dart:developer';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mozhi/platform/android_device.dart';

/// Name of the Android method channel that reports the device's memory
/// (`MainActivity.kt`): `memoryInfo()` -> `{memoryClass: Int,
/// largeMemoryClass: Int, totalMem: Long, lowRam: Boolean}` from
/// `ActivityManager` (see [DeviceMemory]).
const memoryChannelName = 'io.github.aimdi.mozhi/memory';

/// What Android says about the device's memory, for sizing the on-device
/// engines' caches.
@immutable
class DeviceMemory {
  const new({this.memoryClass, this.totalBytes, this.isLowRam = false});

  /// Reads the `memoryInfo` map of [memoryChannelName]; fields of the
  /// wrong type are left out.
  factory fromMap(Map<Object?, Object?> map) => DeviceMemory(
    memoryClass: switch (map['memoryClass']) {
      final int value when value > 0 => value,
      _ => null,
    },
    totalBytes: switch (map['totalMem']) {
      final int value when value > 0 => value,
      _ => null,
    },
    isLowRam: map['lowRam'] == true,
  );

  /// `ActivityManager.getMemoryClass()`: the app's heap budget in MB
  /// (about 128 on 2 GB phones, 256-512 on 8 GB ones); null when unknown.
  final int? memoryClass;

  /// Bytes of RAM (`ActivityManager.MemoryInfo.totalMem`); null when
  /// unknown.
  final int? totalBytes;

  /// `ActivityManager.isLowRamDevice()` (Android Go and the like).
  final bool isLowRam;

  static const int _gib = 1024 * 1024 * 1024;

  /// Bergamot models kept loaded at once (each is 15-40 MB of weights plus
  /// its workspace): 2, just a pivot, on low-RAM devices (under 3 GB, or a
  /// heap class of 128 MB or less without a RAM figure); 4 from 8 GB of
  /// RAM; 3 (the engine's default) otherwise and when unknown.
  int get bergamotModelCacheSize {
    final total = totalBytes;
    final heap = memoryClass;
    if (isLowRam ||
        (total != null && total < 3 * _gib) ||
        (total == null && heap != null && heap <= 128)) {
      return 2;
    }
    if (total != null && total >= 8 * _gib) return 4;
    return 3;
  }

  /// Asks Android over [memoryChannelName] ([channel] in tests). Null
  /// without asking when not on Android ([isAndroid], default
  /// [runsOnAndroid]) and when the platform side cannot tell. Never throws.
  static Future<DeviceMemory?> query({
    MethodChannel? channel,
    bool? isAndroid,
  }) async {
    if (!(isAndroid ?? runsOnAndroid)) return null;
    try {
      final map = await (channel ?? const MethodChannel(memoryChannelName))
          .invokeMapMethod<Object?, Object?>('memoryInfo');
      return map == null ? null : DeviceMemory.fromMap(map);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceMemory &&
      other.memoryClass == memoryClass &&
      other.totalBytes == totalBytes &&
      other.isLowRam == isLowRam;

  @override
  int get hashCode => Object.hash(memoryClass, totalBytes, isLowRam);

  @override
  String toString() =>
      'DeviceMemory(class: $memoryClass MB, total: $totalBytes, '
      'lowRam: $isLowRam)';
}

/// Gives the on-device engines' memory back when the app needs it: runs
/// the [onMemoryPressure] callbacks when the system is short of memory
/// (`didHaveMemoryPressure`, which Flutter raises from Android's
/// `onTrimMemory`, also when the app's UI is hidden on Android 14+) and the
/// [onBackground] callbacks when the app goes to the background (paused).
///
/// The engines register themselves when they are created
/// (`createBergamotOfflineTranslator`, `createOfflineSpeech`). Callbacks
/// run one after another; their errors are logged, never thrown.
class NativeMemoryBudget with WidgetsBindingObserver {
  /// A budget that is not attached to the app: tests call
  /// [didHaveMemoryPressure] and [didChangeAppLifecycleState] themselves.
  new();

  /// The app's budget, attached to [WidgetsBinding] on first use (when the
  /// binding exists).
  static final NativeMemoryBudget instance = NativeMemoryBudget().._attach();

  final _pressure = <Future<void> Function()>[];
  final _background = <Future<void> Function()>[];

  /// Runs [callback] whenever memory runs low.
  void onMemoryPressure(Future<void> Function() callback) =>
      _pressure.add(callback);

  /// Runs [callback] whenever the app goes to the background.
  void onBackground(Future<void> Function() callback) =>
      _background.add(callback);

  @override
  void didHaveMemoryPressure() => unawaited(_run(_pressure, 'memory pressure'));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_run(_background, 'background'));
    }
  }

  void _attach() {
    try {
      WidgetsBinding.instance.addObserver(this);
      // coverage:ignore-start
    } on Object catch (error) {
      // No binding (a test or tool without Flutter): nothing to observe.
      log('Native memory budget not attached', name: 'mozhi', error: error);
    }
    // coverage:ignore-end
  }

  static Future<void> _run(
    List<Future<void> Function()> callbacks,
    String reason,
  ) async {
    for (final callback in [...callbacks]) {
      try {
        await callback();
      } on Object catch (error, stackTrace) {
        log(
          'Freeing native memory on $reason failed',
          name: 'mozhi',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }
}
