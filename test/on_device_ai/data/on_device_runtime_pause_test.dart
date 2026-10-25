import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/data/on_device_runtime.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/platform/privacy_channel.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLlamaEngine engine;
  late StreamController<Object?> pushes;
  late DeviceConditions conditions;
  late DateTime now;
  late OnDeviceRuntime runtime;
  late List<OnDeviceAiStatus> statuses;

  final channel = privacyChannel();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> strain({int thermal = 0, bool powerSave = false}) async {
    pushes.add({'thermal': thermal, 'powerSave': powerSave});
    await pumpEventQueue();
  }

  setUp(() async {
    engine = FakeLlamaEngine();
    pushes = StreamController<Object?>.broadcast();
    now = DateTime(2026, 10, 25, 12);
    // Polling (not used while changes are pushed) answers "no strain".
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'thermalStatus' ? 0 : false,
    );
    // Reading it starts listening.
    conditions = DeviceConditions(
      isAndroid: true,
      events: pushes.stream,
      clock: () => now,
    )..latest;
    statuses = [];
    runtime = OnDeviceRuntime(
      engine: engine,
      catalog: testCatalog,
      pathOf: (id) async => '/m/$id',
      deviceConditions: conditions,
      clock: () => now,
      pauseCheckInterval: const Duration(milliseconds: 20),
    );
    runtime.status.listen(statuses.add);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await runtime.dispose();
    await conditions.dispose();
    await pushes.close();
  });

  test('a request the user just asked for never waits', () async {
    await strain(thermal: 4);
    expect(await runtime.run('gemma', (_) async => 'first'), 'first');
    expect(statuses.whereType<OnDeviceAiPaused>(), isEmpty);
  });

  test('the next parts of a job wait while the phone is hot', () async {
    await strain(thermal: 3);
    final first = Completer<void>();
    final order = <String>[];
    final one = runtime.run('gemma', (_) async {
      order.add('part 1');
      await first.future;
    });
    // Asked for while part 1 runs: the next part of the job.
    final two = runtime.run('gemma', (_) async => order.add('part 2'));
    await pumpEventQueue();
    first.complete();
    await one;
    await pumpEventQueue();
    expect(order, ['part 1']);
    expect(
      runtime.currentStatus,
      const OnDeviceAiPaused('gemma', DeviceStrain.heat),
    );

    // Cooled down: it goes on.
    await strain(thermal: 1);
    await two;
    expect(order, ['part 1', 'part 2']);
    expect(
      statuses,
      contains(const OnDeviceAiPaused('gemma', DeviceStrain.heat)),
    );
    await pumpEventQueue();
    expect(runtime.currentStatus, const OnDeviceAiIdle());
  });

  test('a part asked for right after the last one waits too', () async {
    await runtime.run('gemma', (_) async {});
    await strain(powerSave: true);
    now = now.add(const Duration(seconds: 1));
    final next = runtime.run('gemma', (_) async => 'next');
    await pumpEventQueue();
    expect(
      runtime.currentStatus,
      const OnDeviceAiPaused('gemma', DeviceStrain.batterySaver),
    );
    runtime.continueAnyway();
    expect(await next, 'next');

    // Continue anyway holds for the rest of the job.
    now = now.add(const Duration(seconds: 1));
    expect(await runtime.run('gemma', (_) async => 'rest'), 'rest');

    // A new job after a pause in the work starts without waiting, and its
    // later parts wait again.
    now = now.add(const Duration(minutes: 1));
    expect(await runtime.run('gemma', (_) async => 'new'), 'new');
    final later = runtime.run('gemma', (_) async => 'later');
    await pumpEventQueue();
    expect(runtime.currentStatus, isA<OnDeviceAiPaused>());
    await strain();
    expect(await later, 'later');
  });

  test('cancelling a waiting part stops it', () async {
    await runtime.run('gemma', (_) async {});
    await strain(thermal: 5);
    var cancelled = false;
    var ran = false;
    final next = runtime.run(
      'gemma',
      (_) async => ran = true,
      isCancelled: () => cancelled,
    );
    await pumpEventQueue();
    expect(runtime.currentStatus, isA<OnDeviceAiPaused>());
    cancelled = true;
    expect(await next, isNull);
    expect(ran, isFalse);
    await pumpEventQueue();
    expect(runtime.currentStatus, const OnDeviceAiIdle());
  });

  test('a warm-up never waits', () async {
    await runtime.run('gemma', (_) async {});
    await strain(thermal: 6);
    await runtime.run('gemma', (_) async {}, generating: false);
    expect(statuses.whereType<OnDeviceAiPaused>(), isEmpty);
  });

  test('disposing ends a wait', () async {
    await runtime.run('gemma', (_) async {});
    await strain(thermal: 4);
    final next = runtime.run('gemma', (_) async => 'never');
    await pumpEventQueue();
    await runtime.dispose();
    await expectLater(next, throwsA(isA<Exception>()));
  });

  test('describes the pause', () {
    const paused = OnDeviceAiPaused('gemma', DeviceStrain.heat);
    expect(paused.isPaused, isTrue);
    expect(paused.isLoading, isFalse);
    expect(paused.modelId, 'gemma');
    expect(paused, const OnDeviceAiPaused('gemma', DeviceStrain.heat));
    expect(
      paused,
      isNot(const OnDeviceAiPaused('gemma', DeviceStrain.batterySaver)),
    );
    expect(paused.hashCode, isA<int>());
    expect(paused.toString(), 'OnDeviceAiPaused(gemma, heat)');
    expect(const OnDeviceAiIdle().isPaused, isFalse);
  });
}
