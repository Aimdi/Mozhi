import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/platform/privacy_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(ThermalStatus, () {
    test('maps Android statuses', () {
      expect(ThermalStatus.fromAndroid(0), ThermalStatus.none);
      expect(ThermalStatus.fromAndroid(1), ThermalStatus.light);
      expect(ThermalStatus.fromAndroid(2), ThermalStatus.moderate);
      expect(ThermalStatus.fromAndroid(3), ThermalStatus.severe);
      expect(ThermalStatus.fromAndroid(4), ThermalStatus.critical);
      expect(ThermalStatus.fromAndroid(5), ThermalStatus.emergency);
      expect(ThermalStatus.fromAndroid(6), ThermalStatus.shutdown);
    });

    test('counts -1, null and unknown values as unknown', () {
      expect(ThermalStatus.fromAndroid(-1), ThermalStatus.unknown);
      expect(ThermalStatus.fromAndroid(null), ThermalStatus.unknown);
      expect(ThermalStatus.fromAndroid(7), ThermalStatus.unknown);
    });

    test('is hot from severe on', () {
      expect(
        [
          for (final status in ThermalStatus.values)
            if (status.isHot) status,
        ],
        [
          ThermalStatus.severe,
          ThermalStatus.critical,
          ThermalStatus.emergency,
          ThermalStatus.shutdown,
        ],
      );
    });
  });

  group(DeviceConditionsSnapshot, () {
    test('has no strain when nothing is known', () {
      expect(DeviceConditionsSnapshot.unknown.strain, isNull);
    });

    test('names heat before battery saver', () {
      expect(
        const DeviceConditionsSnapshot(
          thermal: ThermalStatus.critical,
          powerSave: true,
        ).strain,
        DeviceStrain.heat,
      );
      expect(
        const DeviceConditionsSnapshot(
          thermal: ThermalStatus.moderate,
          powerSave: true,
        ).strain,
        DeviceStrain.batterySaver,
      );
      expect(
        const DeviceConditionsSnapshot(thermal: ThermalStatus.moderate).strain,
        isNull,
      );
    });

    test('compares by value', () {
      const a = DeviceConditionsSnapshot(thermal: ThermalStatus.light);
      const b = DeviceConditionsSnapshot(thermal: ThermalStatus.light);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const DeviceConditionsSnapshot(powerSave: true)));
      expect(a.toString(), contains('light'));
    });
  });

  group(DeviceConditions, () {
    final channel = privacyChannel();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> calls;
    late Map<String, Object? Function()> answers;
    late DateTime now;

    setUp(() {
      calls = [];
      now = DateTime(2026, 10, 22, 12);
      answers = {'thermalStatus': () => 0, 'isPowerSaveMode': () => false};
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return answers[call.method]!();
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    DeviceConditions conditions() =>
        DeviceConditions(isAndroid: true, clock: () => now);

    test('reports what Android answers', () async {
      answers = {'thermalStatus': () => 3, 'isPowerSaveMode': () => true};
      final snapshot = await conditions().refresh();
      expect(snapshot.thermal, ThermalStatus.severe);
      expect(snapshot.powerSave, isTrue);
      expect(calls, ['thermalStatus', 'isPowerSaveMode']);
    });

    test('counts errors and a missing platform side as no strain', () async {
      answers = {
        'thermalStatus': () => throw PlatformException(code: 'denied'),
        'isPowerSaveMode': () => null,
      };
      expect(await conditions().refresh(), DeviceConditionsSnapshot.unknown);

      messenger.setMockMethodCallHandler(channel, null);
      expect(await conditions().refresh(), DeviceConditionsSnapshot.unknown);
    });

    test('latest asks in the background once it is stale', () async {
      final device = conditions();
      final changes = <DeviceConditionsSnapshot>[];
      final subscription = device.changes.listen(changes.add);
      addTearDown(subscription.cancel);

      answers = {'thermalStatus': () => 4, 'isPowerSaveMode': () => false};
      // Never asked: the unknown snapshot now, the answer in the background.
      expect(device.latest, DeviceConditionsSnapshot.unknown);
      expect(device.latest, DeviceConditionsSnapshot.unknown);
      await pumpEventQueue();
      expect(calls, ['thermalStatus', 'isPowerSaveMode']);
      expect(device.latest.strain, DeviceStrain.heat);
      expect(changes.single.thermal, ThermalStatus.critical);

      // Fresh: not asked again.
      calls.clear();
      now = now.add(const Duration(seconds: 19));
      expect(device.latest.strain, DeviceStrain.heat);
      await pumpEventQueue();
      expect(calls, isEmpty);

      // Stale: asked again; it cooled down.
      answers = {'thermalStatus': () => 1, 'isPowerSaveMode': () => false};
      now = now.add(const Duration(seconds: 1));
      expect(device.latest.strain, DeviceStrain.heat);
      await pumpEventQueue();
      expect(device.latest.strain, isNull);
      expect(changes.last.thermal, ThermalStatus.light);

      // The same answer is no change.
      now = now.add(const Duration(minutes: 1));
      device.latest;
      await pumpEventQueue();
      expect(changes, hasLength(2));
    });

    test('asks one question at a time', () async {
      final device = conditions();
      final first = device.refresh();
      final second = device.refresh();
      expect(identical(first, second), isTrue);
      await first;
      expect(calls, ['thermalStatus', 'isPowerSaveMode']);
    });

    test('never asks off Android', () async {
      answers = {'thermalStatus': () => 6, 'isPowerSaveMode': () => true};
      // Tests run on a desktop host: the default is not Android.
      final device = DeviceConditions();
      expect(device.latest, DeviceConditionsSnapshot.unknown);
      expect(await device.refresh(), DeviceConditionsSnapshot.unknown);
      expect(DeviceConditions.instance.latest.strain, isNull);
      await pumpEventQueue();
      expect(calls, isEmpty);
    });
  });
}
