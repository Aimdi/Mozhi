import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llama_engine/llama_engine.dart';

import '../helpers/fake_llama_models.dart';

final class _FakeLlamaWorkerChannel implements LlamaWorkerChannel {
  final List<(String op, Map<String, Object?> args)> calls = [];
  bool terminated = false;
  Map<String, Object?> probeResult = const {'supported': true};
  List<String> deltas = const ['Bon', 'jour'];
  Exception? nextError;

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
    void Function(String delta)? onDelta,
  ]) async {
    calls.add((op, arguments));
    if (nextError case final error?) {
      nextError = null;
      throw error;
    }
    return switch (op) {
      'probe' => probeResult,
      'load' => {
        'architecture': 'gemma4',
        'name': 'Gemma 4 E2B',
        'contextLength': 8192,
        'contextSize': arguments['contextSize'] ?? 4096,
        'parameters': 2000000000,
        'sizeBytes': 123456,
        'chatTemplate': true,
        'chatTemplateName': 'gemma4',
      },
      'countTokens' => 14,
      'generate' => () {
        if (onDelta != null) {
          deltas.forEach(onDelta);
        }
        return {
          'promptTokens': 14,
          'generatedTokens': 2,
          'promptMs': 40,
          'generateMs': 80,
          'finishReason': 'stop',
        };
      }(),
      'cancel' || 'unload' => null,
      _ => throw LlamaWorkerException(
        LlamaWorkerErrorKind.protocol,
        'Unknown op $op',
      ),
    };
  }

  @override
  void terminate() {
    terminated = true;
  }
}

void main() {
  group('WebLlamaEngine', () {
    late _FakeLlamaWorkerChannel channel;
    late WebLlamaEngine engine;

    setUp(() {
      channel = _FakeLlamaWorkerChannel();
      engine = WebLlamaEngine(channel);
    });

    tearDown(() => engine.dispose());

    test('probes support, loads model, counts tokens and streams', () async {
      expect(await engine.isSupported(), isTrue);

      final info = await engine.load('gemma-4.gguf', contextSize: 2048);
      expect(engine.loadedModelPath, 'gemma-4.gguf');
      expect(info.architecture, 'gemma4');
      expect(info.contextSize, 2048);

      final tokens = await engine.countTokens(const [
        LlamaChatMessage(LlamaRole.user, 'Hello'),
      ]);
      expect(tokens, 14);

      LlamaGenerateStats? stats;
      final pieces = await engine
          .generate(
            LlamaGenerateRequest(
              messages: const [LlamaChatMessage(LlamaRole.user, 'Hello')],
              onFinish: (value) => stats = value,
            ),
          )
          .toList();
      expect(pieces, ['Bon', 'jour']);
      expect(stats?.generatedTokens, 2);
      expect(stats?.finishReason, LlamaFinishReason.stop);

      await engine.unload();
      expect(engine.loadedModelPath, isNull);
    });

    test('throws LlamaNotLoadedException before load', () async {
      await expectLater(
        engine.countTokens(const [LlamaChatMessage(LlamaRole.user, 'Hi')]),
        throwsA(isA<LlamaNotLoadedException>()),
      );
      await expectLater(
        engine
            .generate(
              const LlamaGenerateRequest(
                messages: [LlamaChatMessage(LlamaRole.user, 'Hi')],
              ),
            )
            .toList(),
        throwsA(isA<LlamaNotLoadedException>()),
      );
    });

    test('maps worker errors and terminates channel on dispose', () async {
      await engine.load('model.gguf');
      channel.nextError = const LlamaWorkerException(
        LlamaWorkerErrorKind.cancelled,
        'cancelled',
      );
      await expectLater(
        engine
            .generate(
              const LlamaGenerateRequest(
                messages: [LlamaChatMessage(LlamaRole.user, 'Hi')],
              ),
            )
            .toList(),
        throwsA(isA<LlamaCancelledException>()),
      );
      await engine.dispose();
      expect(channel.terminated, isTrue);
    });
  });

  group('LlamaCatalogModel mmproj vision projector', () {
    test('parses optional mmproj and exposes supportsVision/totalSize', () {
      final sha = 'a' * 64;
      final projSha = 'b' * 64;
      final model = LlamaCatalogModel.fromJson({
        'id': 'gemma-4-e2b-vision',
        'name': 'gemma-4-e2b-q4.gguf',
        'url': 'https://example.org/models/gemma-4-e2b-q4.gguf',
        'size': 2000000,
        'sha256': sha,
        'role': 'assistant',
        'family': 'gemma4',
        'promptProfile': 'general',
        'displayName': 'Gemma 4 E2B',
        'parameters': '2B',
        'quantization': 'Q4_K_M',
        'contextSize': 4096,
        'minRamMb': 6000,
        'recommendedRamMb': 8000,
        'license': 'Apache-2.0',
        'licenseUrl': 'https://example.org/license',
        'sourceUrl': 'https://example.org/model',
        'mmproj': {
          'name': 'mmproj-gemma-4-f16.gguf',
          'url': 'https://example.org/models/mmproj-gemma-4-f16.gguf',
          'size': 400000,
          'sha256': projSha,
        },
      });
      expect(model.supportsVision, isTrue);
      expect(model.mmproj?.name, 'mmproj-gemma-4-f16.gguf');
      expect(model.totalSize, 2400000);
    });
  });

  group('WebLlamaModelManager & web probes', () {
    late _InMemoryOpfsChannel opfsChannel;
    late Uint8List modelBytes;
    late Uint8List projBytes;
    late LlamaCatalogModel visionModel;

    setUp(() {
      opfsChannel = _InMemoryOpfsChannel();
      modelBytes = fakeModelBytes(2048, seed: 5);
      projBytes = fakeModelBytes(512, seed: 9);
      final base = fakeLlamaModel(
        'gemma-web',
        modelBytes,
        name: 'gemma-web-q4.gguf',
      );
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
          name: 'mmproj-gemma-web.gguf',
          url: Uri.parse(
            'https://models.example/repo/resolve/abc/mmproj-gemma-web.gguf',
          ),
          size: projBytes.length,
          sha256: sha256.convert(projBytes).toString(),
        ),
      );
    });

    test('probeLlamaWorker parses capabilities and handles errors', () async {
      final support = await probeLlamaWorker(opfsChannel);
      expect(support.supported, isTrue);
      expect(support.wasm, isTrue);
      expect(support.opfs, isTrue);
      expect(support.engineAvailable, isTrue);

      opfsChannel.probeResponse = const {
        'supported': false,
        'wasm': true,
        'opfs': true,
        'engineAvailable': false,
      };
      expect((await probeLlamaWorker(opfsChannel)).supported, isFalse);

      opfsChannel.failOp = 'probe';
      expect((await probeLlamaWorker(opfsChannel)).supported, isFalse);
    });

    test('probeLlamaHostMirror parses models/llm/index.json safely', () async {
      final client = MockClient((request) async {
        if (request.url.toString() ==
            'https://app.example/models/llm/index.json') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'kind': 'llm',
              'items': ['hy-mt2-1.8b-q4'],
            }),
            200,
          );
        }
        if (request.url.toString() ==
            'https://html.example/models/llm/index.json') {
          return http.Response('<html><body>SPA fallback</body></html>', 200);
        }
        return http.Response('not found', 404);
      });

      final hosted = await probeLlamaHostMirror(
        client,
        Uri.parse('https://app.example/'),
      );
      expect(hosted.available, isTrue);
      expect(hosted.modelIds, ['hy-mt2-1.8b-q4']);

      // Also resolves cleanly when baseUrl already ends with /models/.
      final fromModels = await probeLlamaHostMirror(
        client,
        Uri.parse('https://app.example/models/'),
      );
      expect(fromModels.available, isTrue);

      final htmlFallback = await probeLlamaHostMirror(
        client,
        Uri.parse('https://html.example/'),
      );
      expect(htmlFallback.available, isFalse);

      final missing = await probeLlamaHostMirror(
        client,
        Uri.parse('https://missing.example/'),
      );
      expect(missing.available, isFalse);
    });

    test(
      'installs, SHA-256 verifies, lists, and deletes models (with mmproj) in '
      'OPFS',
      () async {
        var persisted = false;
        final client = MockClient.streaming((request, _) async {
          final bytes = request.url.path.endsWith(visionModel.name)
              ? modelBytes
              : request.url.path.endsWith(visionModel.mmproj!.name)
              ? projBytes
              : null;
          if (bytes == null) {
            return http.StreamedResponse(Stream.value(const []), 404);
          }
          return http.StreamedResponse(Stream.value(bytes), 200);
        });
        final manager = WebLlamaModelManager(
          channel: opfsChannel,
          httpClient: client,
          requestPersistence: () async => persisted = true,
        );

        final progress = <LlamaDownloadProgress>[];
        final installed = await manager.install(
          visionModel,
          onProgress: progress.add,
        );
        expect(persisted, isTrue);
        expect(installed.id, visionModel.id);
        expect(installed.path, 'models/${visionModel.id}/${visionModel.name}');
        expect(
          installed.projectorPath,
          'models/${visionModel.id}/${visionModel.mmproj!.name}',
        );
        expect(installed.matches(visionModel), isTrue);
        expect(await manager.isInstalled(visionModel), isTrue);
        expect(await manager.isProjectorInstalled(visionModel.id), isTrue);
        expect(progress.last.receivedBytes, visionModel.totalSize);
        expect(progress.last.totalBytes, visionModel.totalSize);

        await manager.delete(visionModel.id);
        expect(await manager.installed(), isEmpty);
      },
    );

    test('enforces OPFS free-space quota and SHA-256 verification', () async {
      final corruptClient = MockClient.streaming((request, _) async {
        final bad = Uint8List.fromList(modelBytes);
        bad[0] ^= 0xff;
        return http.StreamedResponse(Stream.value(bad), 200);
      });
      final tightManager = WebLlamaModelManager(
        channel: opfsChannel,
        httpClient: corruptClient,
        freeSpace: () async => 1024,
      );
      await expectLater(
        tightManager.install(visionModel),
        throwsA(isA<LlamaInsufficientSpaceException>()),
      );

      final verifyingManager = WebLlamaModelManager(
        channel: opfsChannel,
        httpClient: corruptClient,
      );
      await expectLater(
        verifyingManager.install(visionModel),
        throwsA(isA<LlamaChecksumException>()),
      );
      expect(await verifyingManager.installed(), isEmpty);
    });
  });
}

final class _InMemoryOpfsChannel implements LlamaWorkerChannel {
  final Map<String, Uint8List> files = {};
  final Map<String, Map<String, Object?>> manifests = {};
  Map<String, Object?> probeResponse = const {
    'supported': true,
    'wasm': true,
    'opfs': true,
    'syncAccess': true,
    'digest': true,
    'engineAvailable': true,
    'abiVersion': 2,
  };
  String? failOp;

  @override
  Future<Object?> request(
    String op, [
    Map<String, Object?> arguments = const {},
    void Function(String delta)? onDelta,
  ]) async {
    if (failOp == op) {
      throw LlamaWorkerException(LlamaWorkerErrorKind.engine, 'failed $op');
    }
    switch (op) {
      case 'probe':
        return probeResponse;
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
        final paths = (arguments['paths'] as List<Object?>?) ?? const [];
        var total = 0;
        for (final path in paths) {
          total += files[path]?.length ?? 0;
        }
        return {'size': total};
      case 'downloadOpen':
        final path = arguments['path']! as String;
        if (arguments['restart'] == true) files.remove(path);
        return {'size': files[path]?.length ?? 0};
      case 'downloadWrite':
        final path = arguments['path']! as String;
        final at = (arguments['at']! as num).toInt();
        final bytes = arguments['bytes']! as Uint8List;
        final current = files[path] ?? Uint8List(0);
        final nextLen = at + bytes.length > current.length
            ? at + bytes.length
            : current.length;
        final next = Uint8List(nextLen)
          ..setRange(0, current.length, current)
          ..setRange(at, at + bytes.length, bytes);
        files[path] = next;
        return {'size': next.length};
      case 'downloadClose':
        return null;
      case 'install':
        final part = arguments['part']! as String;
        final target = arguments['target']! as String;
        final size = (arguments['size']! as num).toInt();
        final expected = arguments['sha256']! as String;
        final bytes = files.remove(part) ?? Uint8List(0);
        final actual = sha256.convert(bytes).toString();
        if (bytes.length != size || actual != expected) {
          throw LlamaWorkerException(
            LlamaWorkerErrorKind.checksum,
            '$target checksum mismatch',
          );
        }
        files[target] = bytes;
        return {'size': bytes.length};
      case 'commit':
        final dir = arguments['directory']! as String;
        final manifest = Map<String, Object?>.from(
          arguments['manifest']! as Map,
        );
        manifests[dir] = manifest;
        final dl = arguments['downloads'] as String?;
        if (dl != null) {
          files.removeWhere((key, _) => key.startsWith(dl));
        }
        return null;
      case 'remove':
        final path = arguments['path']! as String;
        files.removeWhere((key, _) => key == path || key.startsWith('$path/'));
        manifests.removeWhere(
          (key, _) => key == path || key.startsWith('$path/'),
        );
        return null;
      case 'cleanUp':
        return null;
      default:
        throw LlamaWorkerException(
          LlamaWorkerErrorKind.protocol,
          'Unknown op $op',
        );
    }
  }

  @override
  void terminate() {}
}
