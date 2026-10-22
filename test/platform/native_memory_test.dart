import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/native_memory.dart';

const int _gib = 1024 * 1024 * 1024;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceMemory', () {
    test('reads what Android reports', () {
      expect(
        DeviceMemory.fromMap(const {
          'memoryClass': 256,
          'largeMemoryClass': 512,
          'totalMem': 8 * _gib,
          'lowRam': false,
        }),
        const DeviceMemory(memoryClass: 256, totalBytes: 8 * _gib),
      );
      expect(
        DeviceMemory.fromMap(const {
          'memoryClass': 'big',
          'totalMem': -1,
          'lowRam': true,
        }),
        const DeviceMemory(isLowRam: true),
      );
      expect(DeviceMemory.fromMap(const {}), const DeviceMemory());
    });

    test('sizes the Bergamot model cache', () {
      int size(DeviceMemory memory) => memory.bergamotModelCacheSize;

      expect(size(const DeviceMemory()), 3);
      expect(size(const DeviceMemory(isLowRam: true, totalBytes: 8 * _gib)), 2);
      expect(size(const DeviceMemory(totalBytes: 2 * _gib)), 2);
      expect(size(const DeviceMemory(memoryClass: 128)), 2);
      expect(size(const DeviceMemory(memoryClass: 192)), 3);
      // The RAM figure wins over the heap class.
      expect(
        size(const DeviceMemory(memoryClass: 96, totalBytes: 4 * _gib)),
        3,
      );
      expect(size(const DeviceMemory(totalBytes: 6 * _gib)), 3);
      expect(size(const DeviceMemory(totalBytes: 8 * _gib)), 4);
    });

    test('has value equality and a description', () {
      const memory = DeviceMemory(memoryClass: 256, totalBytes: 42);

      expect(memory, const DeviceMemory(memoryClass: 256, totalBytes: 42));
      expect(
        memory.hashCode,
        const DeviceMemory(memoryClass: 256, totalBytes: 42).hashCode,
      );
      expect(memory, isNot(const DeviceMemory(memoryClass: 256)));
      expect(
        '$memory',
        'DeviceMemory(class: 256 MB, total: 42, lowRam: false)',
      );
    });

    group('query', () {
      const channel = MethodChannel(memoryChannelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late List<MethodCall> calls;

      void answer(Object? Function() reply) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return reply();
        });
      }

      setUp(() => calls = []);
      tearDown(() => messenger.setMockMethodCallHandler(channel, null));

      test('asks Android', () async {
        answer(() => {'memoryClass': 192, 'totalMem': 3 * _gib});

        expect(
          await DeviceMemory.query(isAndroid: true),
          const DeviceMemory(memoryClass: 192, totalBytes: 3 * _gib),
        );
        expect(calls.single.method, 'memoryInfo');
      });

      test('is null when Android cannot tell', () async {
        answer(() => null);
        expect(await DeviceMemory.query(isAndroid: true), isNull);

        answer(() => throw PlatformException(code: 'denied'));
        expect(await DeviceMemory.query(isAndroid: true), isNull);

        messenger.setMockMethodCallHandler(channel, null);
        expect(await DeviceMemory.query(isAndroid: true), isNull);
      });

      test('asks nothing elsewhere', () async {
        answer(() => {'memoryClass': 192});

        expect(await DeviceMemory.query(), isNull);
        expect(await DeviceMemory.query(isAndroid: false), isNull);
        expect(calls, isEmpty);
      });
    });
  });

  group('NativeMemoryBudget', () {
    test(
      'runs the callbacks on memory pressure and in the background',
      () async {
        final budget = NativeMemoryBudget();
        final events = <String>[];
        budget
          ..onMemoryPressure(() async => events.add('trim'))
          ..onMemoryPressure(() async => events.add('unload'))
          ..onBackground(() async => events.add('background'))
          ..didHaveMemoryPressure();
        await pumpEventQueue();
        expect(events, ['trim', 'unload']);

        events.clear();
        [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.resumed,
        ].forEach(budget.didChangeAppLifecycleState);
        await pumpEventQueue();
        expect(events, isEmpty);

        budget.didChangeAppLifecycleState(AppLifecycleState.paused);
        await pumpEventQueue();
        expect(events, ['background']);
      },
    );

    test('a failing callback does not stop the others', () async {
      final budget = NativeMemoryBudget();
      var ran = false;
      budget
        ..onMemoryPressure(() async => throw StateError('engine gone'))
        ..onMemoryPressure(() async => ran = true)
        ..didHaveMemoryPressure();
      await pumpEventQueue();

      expect(ran, isTrue);
    });

    test('the app budget observes the binding', () async {
      var trimmed = 0;
      NativeMemoryBudget.instance.onMemoryPressure(() async => trimmed++);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            SystemChannels.system.name,
            SystemChannels.system.codec.encodeMessage(const {
              'type': 'memoryPressure',
            }),
            (_) {},
          );
      await pumpEventQueue();

      expect(trimmed, 1);
    });
  });
}
