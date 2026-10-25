import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/privacy_channel.dart';

/// Android's thermal status (`PowerManager.THERMAL_STATUS_*`, Android 10+).
enum ThermalStatus {
  /// Not known: before Android 10, off Android, or the system did not tell.
  unknown,
  none,
  light,
  moderate,
  severe,
  critical,
  emergency,
  shutdown;

  /// The status of `PowerManager.getCurrentThermalStatus()`'s [value] (0
  /// for none to 6 for shutdown); [unknown] for -1, null and anything else.
  factory fromAndroid(int? value) => switch (value) {
    final index? when index >= 0 && index < values.length - 1 =>
      values[index + 1],
    _ => unknown,
  };

  /// Severe or worse: the system throttles the CPU hard, and more heavy work
  /// only makes the phone hotter.
  bool get isHot => index >= severe.index;
}

/// Why heavy on-device work (on-device AI) should wait for the user to ask
/// for it: the phone is hot, or battery saver is on.
enum DeviceStrain { heat, batterySaver }

/// What [DeviceConditions] last learnt: the [thermal] status and whether
/// battery saver is on ([powerSave]).
@immutable
class DeviceConditionsSnapshot {
  const new({this.thermal = ThermalStatus.unknown, this.powerSave = false});

  /// Nothing known: no strain.
  static const unknown = DeviceConditionsSnapshot();

  final ThermalStatus thermal;
  final bool powerSave;

  /// The strain heavy work should spare the device from, heat first; null
  /// when there is none (or nothing is known).
  DeviceStrain? get strain => thermal.isHot
      ? DeviceStrain.heat
      : powerSave
      ? DeviceStrain.batterySaver
      : null;

  @override
  bool operator ==(Object other) =>
      other is DeviceConditionsSnapshot &&
      other.thermal == thermal &&
      other.powerSave == powerSave;

  @override
  int get hashCode => Object.hash(thermal, powerSave);

  @override
  String toString() =>
      'DeviceConditionsSnapshot(${thermal.name}, powerSave: $powerSave)';
}

/// Name of the Android event channel of `DeviceConditionsPlugin.kt`:
/// `{thermal: Int, powerSave: Boolean}` when Dart starts listening and on
/// every change (a thermal status listener on Android 10 and later, a
/// battery saver broadcast receiver; both registered only while Dart
/// listens).
const deviceConditionsChannelName = 'io.github.aimdi.mozhi/device_conditions';

/// The phone's heat and battery saver, pushed by `DeviceConditionsPlugin.kt`
/// on the [deviceConditionsChannelName] event channel and, as a fallback,
/// asked from `MainActivity.kt` over the [privacyChannel]
/// (`thermalStatus`, `isPowerSaveMode`).
///
/// [latest] answers at once (for decisions made while the user types) with
/// what was last learnt. The first use starts listening to the pushed
/// changes ([changes] reports every change); while they arrive nothing is
/// polled. Without them (no platform side, the stream failed or ended)
/// [latest] asks again in the background once its answer is older than
/// [maxAge]. Off Android (`isAndroid`, default [runsOnAndroid]: tests on a
/// desktop host) nothing is asked and there is never any strain. Never
/// throws: what the system cannot tell counts as no strain.
class DeviceConditions {
  /// `events` replaces the platform's pushed changes (tests: a fake event
  /// stream of `{thermal, powerSave}` maps).
  new({
    MethodChannel? channel,
    bool? isAndroid,
    this.maxAge = const Duration(seconds: 20),
    DateTime Function()? clock,
    this._events,
  }) : _channel = channel ?? privacyChannel(),
       _isAndroid = isAndroid ?? runsOnAndroid,
       _clock = clock ?? DateTime.now;

  /// Used by the translate screen (`TranslateCubit`, its note).
  static DeviceConditions instance = DeviceConditions();

  final MethodChannel _channel;
  final bool _isAndroid;
  final DateTime Function() _clock;
  final Stream<Object?>? _events;
  StreamSubscription<Object?>? _pushes;

  /// Whether pushed changes arrive (then nothing is polled).
  bool _pushed = false;

  /// How long [latest] is trusted before it is asked again.
  final Duration maxAge;

  DeviceConditionsSnapshot _latest = DeviceConditionsSnapshot.unknown;
  DateTime? _askedAt;
  Future<DeviceConditionsSnapshot>? _asking;
  final _changes = StreamController<DeviceConditionsSnapshot>.broadcast();

  /// What was last learnt ([DeviceConditionsSnapshot.unknown] before the
  /// first answer). Asks again in the background ([refresh]) when that is
  /// older than [maxAge] or was never asked.
  DeviceConditionsSnapshot get latest {
    _listen();
    final askedAt = _askedAt;
    if (_isAndroid &&
        !_pushed &&
        (askedAt == null || _clock().difference(askedAt) >= maxAge)) {
      unawaited(refresh());
    }
    return _latest;
  }

  /// Every change of [latest] (pushed by Android, or polled).
  Stream<DeviceConditionsSnapshot> get changes {
    _listen();
    return _changes.stream;
  }

  /// Whether pushed changes arrive, so [latest] needs no polling.
  @visibleForTesting
  bool get isPushed => _pushed;

  /// Asks Android now (one question at a time) and returns the answer.
  Future<DeviceConditionsSnapshot> refresh() {
    if (!_isAndroid) return Future.value(_latest);
    _listen();
    return _asking ??= _ask().whenComplete(() => _asking = null);
  }

  /// Stops listening to the pushed changes and closes [changes].
  Future<void> dispose() async {
    await _pushes?.cancel();
    _pushes = null;
    _pushed = false;
    await _changes.close();
  }

  /// Starts listening to the pushed changes, once (Android only).
  void _listen() {
    if (!_isAndroid || _pushes != null || _changes.isClosed) return;
    final events =
        _events ??
        const EventChannel(
          deviceConditionsChannelName,
        ).receiveBroadcastStream();
    _pushes = events.listen(
      _onPush,
      // Polling takes over.
      onError: (Object _) => _pushed = false,
      onDone: () => _pushed = false,
    );
  }

  void _onPush(Object? event) {
    if (event is! Map<Object?, Object?>) return;
    final thermal = event['thermal'];
    final powerSave = event['powerSave'];
    _pushed = true;
    _askedAt = _clock();
    _update(
      DeviceConditionsSnapshot(
        thermal: ThermalStatus.fromAndroid(thermal is int ? thermal : null),
        powerSave: powerSave is bool && powerSave,
      ),
    );
  }

  void _update(DeviceConditionsSnapshot next) {
    if (next == _latest) return;
    _latest = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  Future<DeviceConditionsSnapshot> _ask() async {
    _askedAt = _clock();
    final thermal = ThermalStatus.fromAndroid(
      await _invoke<int>('thermalStatus'),
    );
    final powerSave = await _invoke<bool>('isPowerSaveMode') ?? false;
    final next = DeviceConditionsSnapshot(
      thermal: thermal,
      powerSave: powerSave,
    );
    _update(next);
    return next;
  }

  Future<T?> _invoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
