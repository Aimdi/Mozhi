import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/platform/on_device_ai_web.dart' as web;
import 'package:mozhi/settings/models/model_source.dart';

import '../helpers.dart';

class _TestBundle extends CachingAssetBundle {
  new(this.values);

  final Map<String, String> values;

  @override
  Future<ByteData> load(String key) async {
    final value = values[key];
    if (value == null) throw StateError('Missing asset: $key');
    return ByteData.sublistView(utf8.encode(value));
  }
}

final class _FakeWebWorkerChannel implements LlamaWorkerChannel {
  bool supported = true;
  bool terminated = false;
  final Map<String, Uint8List> files = {};
  final Map<String, Map<String, Object?>> manifests = {};

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
    void Function(String delta)? onDelta,
  ]) async {
    switch (op) {
      case 'probe':
        return {
          'supported': supported,
          'wasm': true,
          'opfs': true,
          'digest': true,
          'engineAvailable': supported,
          'abiVersion': 2,
        };
      case 'list':
        return [
          for (final MapEntry(:key, :value) in manifests.entries)
            {
              'directory': key,
              'manifest': value,
              'sizeBytes': value['size'] ?? 0,
            },
        ];
      case 'partialSize':
        return {'size': 0};
      case 'cleanUp':
      case 'unload':
      case 'cancel':
        return null;
      default:
        throw LlamaWorkerException(
          LlamaWorkerErrorKind.protocol,
          'Unexpected op $op',
        );
    }
  }

  @override
  void terminate() => terminated = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OnDeviceModels mmproj totalSize accounting', () {
    late Directory root;
    late Uint8List mainBytes;
    late Uint8List projBytes;
    late LlamaCatalogModel visionModel;

    setUp(() {
      root = Directory.systemTemp.createTempSync('on_device_mmproj_');
      mainBytes = ggufBytes(3000, seed: 4);
      projBytes = ggufBytes(1000, seed: 7);
      final base = fakeOnDeviceModel('vision', mainBytes);
      visionModel = LlamaCatalogModel(
        id: base.id,
        name: base.name,
        url: base.url,
        size: base.size,
        sha256: base.sha256,
        role: base.role,
        family: 'gemma4',
        promptProfile: base.promptProfile,
        displayName: base.displayName,
        parameters: base.parameters,
        quantization: base.quantization,
        minRamMb: base.minRamMb,
        recommendedRamMb: base.recommendedRamMb,
        license: base.license,
        licenseUrl: base.licenseUrl,
        sourceUrl: base.sourceUrl,
        mmproj: LlamaProjectorFile(
          name: 'mmproj-vision.gguf',
          url: Uri.parse('https://models.example/repo/mmproj-vision.gguf'),
          size: projBytes.length,
          sha256: sha256.convert(projBytes).toString(),
        ),
      );
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('uses totalSize for free-space check and download progress', () async {
      final server = modelServer({
        visionModel.name: mainBytes,
        visionModel.mmproj!.name: projBytes,
      });

      // Fails free-space check when space fits mainBytes but not totalSize.
      final tight = OnDeviceModels(
        catalog: LlamaModelCatalog(models: [visionModel]),
        manager: LlamaModelManager(
          root: root,
          httpClient: server,
          freeSpace: (_) async =>
              LlamaModelManager.requiredSpace(mainBytes.length),
        ),
        store: MemoryStore(),
        memory: const DeviceMemory(totalBytes: 12 * 1024 * 1024 * 1024),
        modelSource: () => ModelSource.defaultHosts,
      );
      addTearDown(tight.dispose);
      await tight.ready;

      await expectLater(
        tight.download(visionModel.id),
        throwsA(isA<LlamaInsufficientSpaceException>()),
      );

      // Succeeds when enough space exists, reporting progress against
      // totalSize.
      final models = OnDeviceModels(
        catalog: LlamaModelCatalog(models: [visionModel]),
        manager: LlamaModelManager(
          root: root,
          httpClient: server,
          freeSpace: (_) async =>
              LlamaModelManager.requiredSpace(visionModel.totalSize),
        ),
        store: MemoryStore(),
        memory: const DeviceMemory(totalBytes: 12 * 1024 * 1024 * 1024),
        modelSource: () => ModelSource.defaultHosts,
      );
      addTearDown(models.dispose);
      await models.ready;

      final fractions = <double>[];
      await models.download(visionModel.id, onProgress: fractions.add);
      expect(fractions.first, 0.0);
      expect(fractions.any((f) => f > 0.5 && f < 1.0), isTrue);
      expect(fractions.last, 1.0);
      expect(await models.manager.isProjectorInstalled(visionModel.id), isTrue);
    });
  });

  group('web.createOnDeviceAi', () {
    final emptyCatalog = jsonEncode({
      'schemaVersion': LlamaModelCatalog.schemaVersion,
      'models': <Object?>[],
    });

    test('returns null gracefully when WASM probe is unsupported', () async {
      final channel = _FakeWebWorkerChannel()..supported = false;
      final ai = await web.createOnDeviceAi(
        store: MemoryStore(),
        bundle: _TestBundle({LlamaModelCatalog.assetKey: emptyCatalog}),
        channel: channel,
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      expect(ai, isNull);
    });

    test('returns null when thisServer mirror lacks models/llm/index.json and '
        'no model is installed', () async {
      final channel = _FakeWebWorkerChannel();
      final ai = await web.createOnDeviceAi(
        store: MemoryStore(),
        bundle: _TestBundle({LlamaModelCatalog.assetKey: emptyCatalog}),
        channel: channel,
        httpClient: MockClient((_) async => http.Response('not found', 404)),
        modelSource: () => const ModelSource(kind: ModelSourceKind.thisServer),
        hostBaseUrl: () => Uri.parse('https://mozhi.example/'),
      );
      expect(ai, isNull);
    });

    test('instantiates OnDeviceAi backed by WebLlamaEngine and '
        'WebLlamaModelManager when WASM and mirror are available', () async {
      final channel = _FakeWebWorkerChannel();
      final ai = await web.createOnDeviceAi(
        store: MemoryStore(),
        bundle: _TestBundle({LlamaModelCatalog.assetKey: emptyCatalog}),
        channel: channel,
        httpClient: MockClient((request) async {
          if (request.url.path == '/models/llm/index.json') {
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'kind': 'llm',
                'items': ['hy-mt2-1.8b-q4'],
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
        modelSource: () => const ModelSource(kind: ModelSourceKind.thisServer),
        hostBaseUrl: () => Uri.parse('https://mozhi.example/'),
      );
      expect(ai, isNotNull);
      expect(ai!.runtime.engine, isA<WebLlamaEngine>());
      expect(ai.models.manager, isA<WebLlamaModelManager>());
      expect(ai.engineBuild?.library, isNotEmpty);
      await ai.dispose();
      expect(channel.terminated, isTrue);
    });
  });
}
