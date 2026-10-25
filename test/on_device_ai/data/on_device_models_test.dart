import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:llama_engine/llama_engine.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:path/path.dart' as p;

import '../helpers.dart';

class _FailingStore implements KeyValueStore {
  @override
  Future<void> delete(String key) async => throw StateError('store');

  @override
  Future<String?> read(String key) async => throw StateError('store');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('store');
}

const int _gib = 1024 * 1024 * 1024;

void main() {
  late Directory root;
  late Uint8List hyBytes;
  late Uint8List gemmaBytes;
  late Uint8List qwenBytes;
  late LlamaCatalogModel hy;
  late LlamaCatalogModel gemma;
  late LlamaCatalogModel qwen;
  late LlamaModelCatalog catalog;
  late List<http.BaseRequest> requests;
  late MemoryStore store;
  final created = <OnDeviceModels>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('on_device_models_');
    hyBytes = ggufBytes(3000);
    gemmaBytes = ggufBytes(4000, seed: 2);
    qwenBytes = ggufBytes(2000, seed: 3);
    hy = fakeOnDeviceModel('hy', hyBytes, role: LlamaModelRole.translation);
    gemma = fakeOnDeviceModel(
      'gemma',
      gemmaBytes,
      minRamMb: 7000,
      recommendedRamMb: 11000,
    );
    qwen = fakeOnDeviceModel('qwen', qwenBytes);
    catalog = LlamaModelCatalog(models: [hy, gemma, qwen]);
    requests = [];
    store = MemoryStore();
  });

  tearDown(() async {
    for (final models in created) {
      await models.dispose();
    }
    created.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  OnDeviceModels create({
    http.Client? client,
    DeviceMemory? memory = const DeviceMemory(totalBytes: 12 * _gib),
    Future<bool> Function()? isMetered,
    ModelSource Function()? source,
    KeyValueStore? keyValueStore,
    Future<int?> Function(String path)? freeSpace,
  }) {
    final models = OnDeviceModels(
      catalog: catalog,
      manager: LlamaModelManager(
        root: root,
        freeSpace: freeSpace,
        httpClient:
            client ??
            modelServer({
              'hy.gguf': hyBytes,
              'gemma.gguf': gemmaBytes,
              'qwen.gguf': qwenBytes,
            }, requests: requests),
      ),
      store: keyValueStore ?? store,
      memory: memory,
      isMeteredConnection: isMetered,
      modelSource: source ?? () => ModelSource.defaultHosts,
    );
    created.add(models);
    return models;
  }

  group('fitOf', () {
    test('compares the RAM with the model minimum and recommendation', () {
      OnDeviceFit fit(DeviceMemory? memory, LlamaCatalogModel model) =>
          create(memory: memory).fitOf(model);
      const eight = DeviceMemory(totalBytes: 7600 * 1024 * 1024);
      expect(fit(eight, hy), OnDeviceFit.ok);
      expect(fit(eight, gemma), OnDeviceFit.slow);
      expect(
        fit(const DeviceMemory(totalBytes: 12 * _gib), gemma),
        OnDeviceFit.ok,
      );
      expect(
        fit(const DeviceMemory(totalBytes: 4 * _gib), gemma),
        OnDeviceFit.tooBig,
      );
      expect(
        fit(const DeviceMemory(totalBytes: 5 * _gib), hy),
        OnDeviceFit.slow,
      );
      expect(
        fit(const DeviceMemory(totalBytes: 3 * _gib), hy),
        OnDeviceFit.tooBig,
      );
      // Android Go fits nothing; an unknown size is unknown.
      expect(
        fit(const DeviceMemory(totalBytes: 12 * _gib, isLowRam: true), hy),
        OnDeviceFit.tooBig,
      );
      expect(fit(const DeviceMemory(isLowRam: true), hy), OnDeviceFit.tooBig);
      expect(
        fit(const DeviceMemory(memoryClass: 256), hy),
        OnDeviceFit.unknown,
      );
      expect(fit(null, hy), OnDeviceFit.unknown);
    });
  });

  group('download', () {
    test('installs the model, chooses it and fires changes', () async {
      final models = create();
      await models.ready;
      expect(models.translationModel, isNull);
      final changes = <void>[];
      final subscription = models.changes.listen(changes.add);
      final progress = <double>[];
      await models.download('hy', onProgress: progress.add);
      expect(progress.last, 1);
      expect(models.translationModel, 'hy');
      expect(models.assistantModel, isNull);
      expect(store.values[OnDeviceModels.translationModelKey], 'hy');
      expect(await models.pathOf('hy'), endsWith('hy.gguf'));
      expect(File((await models.pathOf('hy'))!).readAsBytesSync(), hyBytes);
      expect(await models.pathOf('qwen'), isNull);
      expect(await models.pathOf('unknown'), isNull);
      expect(requests.single.url.host, 'models.example');
      await Future<void>.delayed(Duration.zero);
      expect(changes, isNotEmpty);
      await subscription.cancel();

      final listed = await models.models();
      expect(listed.map((m) => m.id), ['hy', 'gemma', 'qwen']);
      expect(listed.first.installed, isTrue);
      expect(listed.first.role, LlamaModelRole.translation);
      expect(listed.first.fit, OnDeviceFit.ok);
      expect(listed[1].installed, isFalse);
      expect(
        listed.first,
        OnDeviceModel(model: hy, fit: OnDeviceFit.ok, installed: true),
      );
    });

    test('a later download becomes the chosen assistant', () async {
      final models = create();
      await models.download('gemma');
      expect(models.assistantModel, 'gemma');
      await models.download('qwen');
      expect(models.assistantModel, 'qwen');
      await models.selectAssistantModel('gemma');
      expect(models.assistantModel, 'gemma');
      expect(store.values[OnDeviceModels.assistantModelKey], 'gemma');
      // Back to the default: the first installed one.
      await models.selectAssistantModel(null);
      expect(models.assistantModel, 'gemma');
      expect(store.values, isNot(contains(OnDeviceModels.assistantModelKey)));
    });

    test('follows the model source', () async {
      final models = create(
        source: () => const ModelSource(
          kind: ModelSourceKind.custom,
          customUrl: 'https://mirror.example/models/',
          fallbackToDefault: true,
        ),
      );
      await models.download('qwen');
      expect(
        models.manager.mirror,
        Uri.parse('https://mirror.example/models/'),
      );
      expect(models.manager.fallbackToDefault, isTrue);
      expect(
        requests.single.url.toString(),
        'https://mirror.example/models/llm/qwen.gguf',
      );
    });

    test("downloads from the settings' model source by default", () async {
      final models = OnDeviceModels(
        catalog: catalog,
        manager: LlamaModelManager(
          root: root,
          httpClient: modelServer({'qwen.gguf': qwenBytes}, requests: requests),
        ),
        store: store,
      );
      created.add(models);
      await models.download('qwen');
      expect(models.manager.mirror, ModelSource.current.mirror());
      expect(models.fitOf(qwen), OnDeviceFit.unknown);
    });

    test('asks first on a metered network when Wi-Fi only', () async {
      final models = create(isMetered: () async => true);
      await expectLater(
        models.download('hy'),
        throwsA(isA<OnDeviceModelMeteredException>()),
      );
      expect(requests, isEmpty);
      await models.download('hy', overMeteredNetwork: true);
      expect(models.translationModel, 'hy');
      expect(
        const OnDeviceModelMeteredException().toString(),
        contains('Metered'),
      );
    });

    test('downloads on a metered network when Wi-Fi only is off', () async {
      store.values[OfflineModelsCubit.wifiOnlyKey] = 'false';
      final models = create(isMetered: () async => true);
      expect(await models.wifiOnly(), isFalse);
      await models.download('hy');
      expect(await models.pathOf('hy'), isNotNull);
    });

    test('Wi-Fi only stays on when the store fails', () async {
      final models = create(keyValueStore: _FailingStore());
      expect(await models.wifiOnly(), isTrue);
      // The choice is kept for this run.
      await models.download('hy');
      expect(models.translationModel, 'hy');
    });

    test('refuses a model this device lacks the memory for', () async {
      final models = create(memory: const DeviceMemory(totalBytes: 4 * _gib));
      await expectLater(
        models.download('gemma'),
        throwsA(
          isA<OnDeviceModelTooBigException>()
              .having((e) => e.model, 'model', 'gemma')
              .having((e) => e.toString(), 'toString', contains('gemma')),
        ),
      );
      expect(requests, isEmpty);
    });

    test('refuses an unknown id', () async {
      await expectLater(create().download('x'), throwsArgumentError);
    });

    test('a second call joins the running download', () async {
      final gate = Completer<void>();
      final models = create(
        client: _GatedClient(gate.future, {'qwen.gguf': qwenBytes}, requests),
      );
      final first = models.download('qwen');
      await Future<void>.delayed(Duration.zero);
      expect(models.downloads, {'qwen': 0.0});
      final progress = <double>[];
      final second = models.download('qwen', onProgress: progress.add);
      gate.complete();
      await Future.wait([first, second]);
      expect(requests, hasLength(1));
      expect(progress.last, 1);
      expect(models.downloads, isEmpty);
    });

    test('cancelDownload stops it and keeps the partial download', () async {
      final release = Completer<void>();
      final models = create(
        client: _StallingClient(qwenBytes, 500, release.future),
      );
      final progress = <double>[];
      final download = models.download('qwen', onProgress: progress.add);
      while (!progress.any((fraction) => fraction > 0)) {
        await Future<void>.delayed(Duration.zero);
      }
      models.cancelDownload('qwen');
      await expectLater(
        download,
        throwsA(isA<LlamaDownloadCancelledException>()),
      );
      release.complete();
      final qwenState = (await models.models()).last;
      expect(qwenState.installed, isFalse);
      expect(qwenState.partialBytes, 500);
      expect(models.assistantModel, isNull);
    });
  });

  group('choices', () {
    test(
      'are read back at start and fall back to an installed model',
      () async {
        final first = create();
        await first.download('gemma');
        await first.download('qwen');
        await first.download('hy');

        store.values[OnDeviceModels.assistantModelKey] = 'gemma';
        final again = create();
        expect(again.assistantModel, isNull, reason: 'not read yet');
        await again.ready;
        expect(again.assistantModel, 'gemma');
        expect(again.translationModel, 'hy');

        await again.delete('gemma');
        expect(again.assistantModel, 'qwen');
        store.values[OnDeviceModels.translationModelKey] = 'qwen';
        final wrongRole = create();
        await wrongRole.ready;
        expect(wrongRole.translationModel, 'hy');
      },
    );

    test('reject a model of another role', () async {
      final models = create();
      expect(() => models.selectTranslationModel('qwen'), throwsArgumentError);
      expect(() => models.selectAssistantModel('hy'), throwsArgumentError);
      expect(() => models.selectAssistantModel('x'), throwsArgumentError);
      await models.selectTranslationModel('hy');
      expect(store.values[OnDeviceModels.translationModelKey], 'hy');
      expect(models.translationModel, isNull, reason: 'not installed');
    });
  });

  group('importFiles', () {
    late Directory picked;

    setUp(() => picked = Directory(p.join(root.path, 'picked'))..createSync());

    String write(String name, List<int> bytes) =>
        (File(p.join(picked.path, name))..writeAsBytesSync(bytes)).path;

    test('installs and chooses the models among the files', () async {
      final models = create(memory: const DeviceMemory(totalBytes: 4 * _gib));
      final result = await models.importFiles([
        write('hy.gguf', hyBytes),
        write('renamed.gguf', gemmaBytes),
        write('notes.txt', [1, 2]),
      ]);
      expect(result.installed, ['hy', 'gemma']);
      expect(result.models, {
        'hy': LlamaImportStatus.installed,
        'gemma': LlamaImportStatus.installed,
      });
      expect(result.unmatchedFiles, 1);
      expect(result.errors, isEmpty);
      // Too big for this phone, installed anyway (the user was warned).
      expect(models.assistantModel, 'gemma');
      expect(models.translationModel, 'hy');
      expect(requests, isEmpty);
      expect(File(p.join(picked.path, 'hy.gguf')).existsSync(), isTrue);
    });

    test('moves the files when asked, without choosing them', () async {
      final models = create();
      await models.download('qwen');
      final path = write('gemma.gguf', gemmaBytes);
      final result = await models.importFiles(
        [path],
        move: true,
        choose: false,
      );
      expect(result.installed, ['gemma']);
      expect(File(path).existsSync(), isFalse);
      expect(models.assistantModel, 'qwen');
    });

    test('reports damaged files and failures', () async {
      final models = create();
      final damaged = Uint8List.fromList(hyBytes)..[0] ^= 1;
      var result = await models.importFiles([write('hy.gguf', damaged)]);
      expect(result.models, {'hy': LlamaImportStatus.checksumMismatch});

      models.manager.modelsDirectory.deleteSync(recursive: true);
      File(p.join(root.path, 'models')).writeAsStringSync('in the way');
      result = await models.importFiles([write('qwen.gguf', qwenBytes)]);
      expect(result.models, {'qwen': LlamaImportStatus.failed});
      expect(result.errors['qwen'], isA<FileSystemException>());
      expect(
        const OnDeviceImportResult(models: {'hy': LlamaImportStatus.installed}),
        const OnDeviceImportResult(models: {'hy': LlamaImportStatus.installed}),
      );
    });
  });

  group('delete', () {
    test('delete removes a model and its choice falls back', () async {
      final models = create();
      await models.download('hy');
      await models.delete('hy');
      expect(models.translationModel, isNull);
      expect(await models.pathOf('hy'), isNull);
    });

    test('deleteAll removes every model and the choices', () async {
      final models = create();
      await models.download('hy');
      await models.download('qwen');
      await models.deleteAll();
      expect(models.translationModel, isNull);
      expect(models.assistantModel, isNull);
      expect(store.values, isEmpty);
      expect(models.manager.modelsDirectory.existsSync(), isFalse);
      expect((await models.models()).where((m) => m.installed), isEmpty);
    });

    test('deleteAll reports the first failure after trying the rest', () async {
      final models = create(keyValueStore: _FailingStore());
      await expectLater(models.deleteAll(), throwsStateError);
    });
  });

  test('a folder that cannot be read lists nothing installed', () async {
    File(p.join(root.path, 'models')).writeAsStringSync('not a folder');
    final models = create();
    await models.ready;
    expect((await models.models()).where((m) => m.installed), isEmpty);
    expect(models.downloads, isEmpty);
  });

  group('free space and picked documents', () {
    test('a download that cannot fit fails before the metered check', () async {
      var askedMetered = false;
      final models = create(
        freeSpace: (_) async => 10,
        isMetered: () async {
          askedMetered = true;
          return true;
        },
      );
      await models.ready;
      await expectLater(
        models.download('hy'),
        throwsA(isA<LlamaInsufficientSpaceException>()),
      );
      expect(askedMetered, isFalse);
      expect(requests, isEmpty);
    });

    test('installs picked documents copied straight into staging', () async {
      final models = create();
      await models.ready;
      final result = await models.importSources([
        _Document('hy.gguf', hyBytes),
      ]);
      expect(result.installed, ['hy']);
      expect(models.translationModel, 'hy');
      final unchosen = await models.importSources([
        _Document('qwen.gguf', qwenBytes),
      ], choose: false);
      expect(unchosen.installed, ['qwen']);
      expect(models.assistantModel, 'qwen');
    });
  });
}

/// Answers once [gate] completes.
class _GatedClient extends http.BaseClient {
  new(this.gate, this.files, this.requests);

  final Future<void> gate;
  final Map<String, Uint8List> files;
  final List<http.BaseRequest> requests;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await gate;
    return http.StreamedResponse(
      Stream.value(files[request.url.pathSegments.last]!),
      200,
    );
  }
}

/// Sends [stallAfter] bytes of [bytes], then the rest once [release]
/// completes.
class _StallingClient extends http.BaseClient {
  new(this.bytes, this.stallAfter, this.release);

  final Uint8List bytes;
  final int stallAfter;
  final Future<void> release;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> body() async* {
      yield bytes.sublist(0, stallAfter);
      await release;
      yield bytes.sublist(stallAfter);
    }

    return http.StreamedResponse(body(), 200);
  }
}

/// A picked document for [OnDeviceModels.importSources].
class _Document implements LlamaImportSource {
  new(this.name, this.bytes);

  @override
  final String name;

  final List<int> bytes;

  @override
  int? get length => bytes.length;

  @override
  Future<int> copyTo(File destination, {required int maxBytes}) async {
    await destination.writeAsBytes(bytes, flush: true);
    return bytes.length;
  }
}
