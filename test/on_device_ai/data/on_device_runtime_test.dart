import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/data/on_device_runtime.dart';

import 'helpers.dart';

void main() {
  late FakeLlamaEngine engine;
  late Map<String, String> paths;
  late OnDeviceRuntime runtime;
  late List<OnDeviceAiStatus> statuses;

  OnDeviceRuntime newRuntime({
    Duration idleUnloadAfter = const Duration(minutes: 2),
  }) {
    final runtime = OnDeviceRuntime(
      engine: engine,
      catalog: testCatalog,
      pathOf: (id) async => paths[id],
      idleUnloadAfter: idleUnloadAfter,
    );
    runtime.status.listen(statuses.add);
    return runtime;
  }

  setUp(() {
    engine = FakeLlamaEngine();
    paths = {'hy-mt2': '/m/hy-mt2', 'gemma': '/m/gemma'};
    statuses = [];
    runtime = newRuntime();
  });

  tearDown(() => runtime.dispose());

  test('loads the model with its catalogue context, then runs', () async {
    final result = await runtime.run('gemma', (loaded) async {
      expect(loaded.model, gemmaModel);
      expect(loaded.engine, same(engine));
      expect(loaded.contextSize, 4096);
      expect(runtime.currentStatus, const OnDeviceAiGenerating('gemma'));
      return 42;
    });
    expect(result, 42);
    expect(engine.loads, [('/m/gemma', 4096)]);
    expect(runtime.loadedModelId, 'gemma');
    await pumpEventQueue();
    expect(statuses, const [
      OnDeviceAiLoading('gemma'),
      OnDeviceAiGenerating('gemma'),
      OnDeviceAiIdle(),
    ]);
    expect(runtime.currentStatus, const OnDeviceAiIdle());
  });

  test('keeps a loaded model and switches to another one', () async {
    await runtime.run('gemma', (_) async {});
    await runtime.run('gemma', (_) async {});
    expect(engine.loads, hasLength(1));
    await runtime.run('hy-mt2', (_) async {});
    expect(engine.loads.last, ('/m/hy-mt2', 4096));
    expect(runtime.loadedModelId, 'hy-mt2');
  });

  test('the context is at most what the model was trained with', () async {
    engine.trainedContext = 2048;
    await runtime.run('gemma', (loaded) async {
      expect(loaded.contextSize, 2048);
    });
    // A loaded context the engine doesn't report: the catalogue's, at most
    // the trained one.
    engine.reportsContext = false;
    await runtime.unload();
    await runtime.run('gemma', (loaded) async {
      expect(loaded.contextSize, 2048);
    });
    engine.trainedContext = 0;
    await runtime.unload();
    await runtime.run('gemma', (loaded) async {
      expect(loaded.contextSize, 4096);
    });
  });

  test('a model that is not installed fails', () async {
    for (final id in ['qwen', 'unknown']) {
      await expectLater(
        runtime.run(id, (_) async {}),
        throwsA(
          isA<LlmApiException>().having(
            (e) => e.message,
            'message',
            'The on-device model "$id" is not installed.',
          ),
        ),
      );
    }
    expect(engine.loads, isEmpty);
    await pumpEventQueue();
    expect(statuses.first, isA<OnDeviceAiError>());
    expect(statuses.first.modelId, 'qwen');
    expect(statuses.last, const OnDeviceAiIdle());
  });

  test('a model that cannot be loaded fails with the cause', () async {
    engine.loadError = Exception('out of memory');
    await expectLater(
      runtime.run('gemma', (_) async {}),
      throwsA(
        isA<LlmApiException>()
            .having((e) => e.message, 'message', contains('could not be'))
            .having((e) => e.body, 'body', contains('out of memory')),
      ),
    );
    expect(runtime.loadedModelId, isNull);
  });

  test('a failing request reports the error, then idle', () async {
    await expectLater(
      runtime.run<void>('gemma', (_) async => throw StateError('boom')),
      throwsStateError,
    );
    await pumpEventQueue();
    expect(statuses.sublist(statuses.length - 2), [
      isA<OnDeviceAiError>().having((s) => s.error, 'error', isStateError),
      const OnDeviceAiIdle(),
    ]);
  });

  test('runs one request at a time, in order', () async {
    final order = <String>[];
    final gate = Completer<void>();
    final first = runtime.run('gemma', (_) async {
      order.add('first starts');
      await gate.future;
      order.add('first ends');
    });
    final second = runtime.run('hy-mt2', (_) async => order.add('second'));
    await pumpEventQueue();
    expect(order, ['first starts']);
    gate.complete();
    await Future.wait([first, second]);
    expect(order, ['first starts', 'first ends', 'second']);
  });

  test('a request cancelled while it waited runs nothing', () async {
    final result = await runtime.run(
      'gemma',
      (_) async => 1,
      isCancelled: () => true,
    );
    expect(result, isNull);
    expect(engine.loads, isEmpty);
  });

  test('a warm-up loads without generating', () async {
    await runtime.run('gemma', (_) async {}, generating: false);
    await pumpEventQueue();
    expect(statuses, const [OnDeviceAiLoading('gemma'), OnDeviceAiIdle()]);
  });

  group('unload', () {
    test('frees the model when nothing runs', () async {
      await runtime.run('gemma', (_) async {});
      await runtime.unload();
      expect(engine.unloads, 1);
      expect(runtime.loadedModelId, isNull);
      // Nothing loaded: nothing to do.
      await runtime.unload();
      expect(engine.unloads, 1);
      await runtime.run('gemma', (_) async {});
      expect(engine.loads, hasLength(2));
    });

    test('waits for the running request', () async {
      final gate = Completer<void>();
      final running = runtime.run('gemma', (_) => gate.future);
      await pumpEventQueue();
      await runtime.unload();
      expect(engine.unloads, 0);
      gate.complete();
      await running;
      await pumpEventQueue();
      expect(engine.unloads, 1);
    });

    test('happens after the idle time', () async {
      runtime = newRuntime(idleUnloadAfter: const Duration(milliseconds: 20));
      await runtime.run('gemma', (_) async {});
      expect(engine.unloads, 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(engine.unloads, 1);
    });

    test('a new request stops the idle timer', () async {
      runtime = newRuntime(idleUnloadAfter: const Duration(milliseconds: 40));
      await runtime.run('gemma', (_) async {});
      final gate = Completer<void>();
      final running = runtime.run('gemma', (_) => gate.future);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(engine.unloads, 0);
      gate.complete();
      await running;
    });
  });

  test('installed lists the installed catalogue models', () async {
    expect(await runtime.installed(), [hyMtModel, gemmaModel]);
  });

  test('a request still waiting when disposed fails', () async {
    final gate = Completer<void>();
    final running = runtime.run('gemma', (_) => gate.future);
    final waiting = runtime.run('hy-mt2', (_) async {});
    await pumpEventQueue();
    await runtime.dispose();
    gate.complete();
    await running;
    await expectLater(waiting, throwsA(isA<LlmApiException>()));
    expect(engine.loads, hasLength(1));
  });

  test('dispose stops the engine; later requests fail', () async {
    await runtime.run('gemma', (_) async {});
    await runtime.dispose();
    expect(engine.cancels, 1);
    expect(engine.disposed, isTrue);
    expect(runtime.loadedModelId, isNull);
    await expectLater(
      runtime.run('gemma', (_) async {}),
      throwsA(isA<LlmApiException>()),
    );
    await runtime.unload();
    await runtime.dispose();
    expect(engine.unloads, 0);
  });
}
