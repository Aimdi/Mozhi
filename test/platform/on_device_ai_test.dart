import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/platform/on_device_ai_io.dart';
import 'package:mozhi/platform/on_device_ai_web.dart' as web;
import 'package:path/path.dart' as p;

import '../on_device_ai/data/helpers.dart';

class _Bundle extends CachingAssetBundle {
  new(this.values);

  final Map<String, String> values;

  @override
  Future<ByteData> load(String key) async {
    final value = values[key];
    if (value == null) throw StateError('Unable to load asset: $key');
    return ByteData.sublistView(utf8.encode(value));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  final catalog = jsonEncode({
    'schemaVersion': LlamaModelCatalog.schemaVersion,
    'models': <Object?>[],
  });

  setUp(() => support = Directory.systemTemp.createTempSync('support_'));
  tearDown(() => support.deleteSync(recursive: true));

  test('is not created where llama.cpp cannot run', () async {
    expect(llamaPlatformSupported, isFalse);
    expect(await createOnDeviceAi(store: MemoryStore()), isNull);
    expect(await web.createOnDeviceAi(store: MemoryStore()), isNull);
  });

  test('keeps the models in the support directory and cleans up', () async {
    final staging = Directory(
      p.join(support.path, onDeviceAiFolder, 'models', '.staging', 'x'),
    )..createSync(recursive: true);
    final engine = FakeLlamaEngine();
    final ai = await createOnDeviceAi(
      store: MemoryStore(),
      bundle: _Bundle({LlamaModelCatalog.assetKey: catalog}),
      supportDirectory: () async => support,
      isAvailable: true,
      engine: engine,
      deviceMemory: () async => null,
    );
    expect(ai, isNotNull);
    expect(ai!.models.catalog.isEmpty, isTrue);
    expect(ai.models.manager.root.path, p.join(support.path, onDeviceAiFolder));
    expect(ai.providers, isEmpty);
    expect(ai.runtime.engine, same(engine));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(staging.existsSync(), isFalse);
    await ai.dispose();
    expect(engine.disposed, isTrue);
  });

  test('unloads in the background and on memory pressure', () async {
    final budget = NativeMemoryBudget();
    final engine = FakeLlamaEngine();
    final ai = await createOnDeviceAi(
      store: MemoryStore(),
      bundle: _Bundle({LlamaModelCatalog.assetKey: catalog}),
      supportDirectory: () async => support,
      isAvailable: true,
      engine: engine,
      memoryBudget: budget,
      deviceMemory: () async => null,
    );
    // Nothing loaded: nothing to free, and no failure.
    budget
      ..didChangeAppLifecycleState(AppLifecycleState.paused)
      ..didHaveMemoryPressure();
    await pumpEventQueue();
    expect(engine.unloads, 0);
    await ai!.dispose();
  });

  test('is not created when the catalogue cannot be loaded', () async {
    final ai = await createOnDeviceAi(
      store: MemoryStore(),
      bundle: _Bundle({}),
      supportDirectory: () async => support,
      isAvailable: true,
      engine: FakeLlamaEngine(),
      deviceMemory: () async => null,
    );
    expect(ai, isNull);
  });
}
