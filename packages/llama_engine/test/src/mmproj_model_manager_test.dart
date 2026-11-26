import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_llama_models.dart';

void main() {
  late Directory root;
  late Uint8List mainBytes;
  late Uint8List projBytes;
  late LlamaProjectorFile mmproj;
  late LlamaCatalogModel visionModel;
  late LlamaModelCatalog catalog;

  setUp(() {
    root = Directory.systemTemp.createTempSync('llama_mmproj_');
    mainBytes = fakeModelBytes(4000, seed: 11);
    projBytes = fakeModelBytes(1500, seed: 29);
    mmproj = LlamaProjectorFile(
      name: 'mmproj-gemma-4-f16.gguf',
      url: Uri.parse(
        'https://models.example/repo/resolve/abc/mmproj-gemma-4-f16.gguf',
      ),
      size: projBytes.length,
      sha256: sha256.convert(projBytes).toString(),
    );
    final base = fakeLlamaModel(
      'gemma-4-vision',
      mainBytes,
      name: 'gemma-4-vision-q4.gguf',
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
      mmproj: mmproj,
    );
    catalog = LlamaModelCatalog(models: [visionModel]);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MockClient serverClient({
    bool corruptProjector = false,
    int? failProjectorAfter,
    List<http.BaseRequest>? recorded,
  }) => MockClient.streaming((request, _) async {
    recorded?.add(request);
    final path = request.url.path;
    Uint8List? body;
    var failAfter = -1;
    if (path.endsWith(visionModel.name)) {
      body = Uint8List.fromList(mainBytes);
    } else if (path.endsWith(mmproj.name)) {
      body = Uint8List.fromList(projBytes);
      if (corruptProjector) body[body.length - 1] ^= 0xff;
      failAfter = failProjectorAfter ?? -1;
    }
    if (body == null) {
      return http.StreamedResponse(Stream.value(utf8.encode('missing')), 404);
    }
    var status = 200;
    final headers = <String, String>{};
    final range = request.headers['Range'];
    if (range != null) {
      final total = body.length;
      final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
      body = body.sublist(start);
      status = 206;
      headers['content-range'] = 'bytes $start-${total - 1}/$total';
    }
    Stream<List<int>> stream() async* {
      if (failAfter >= 0) {
        yield body!.sublist(0, failAfter.clamp(0, body.length));
        throw const SocketException('cut during mmproj');
      }
      yield body!;
    }

    return http.StreamedResponse(stream(), status, headers: headers);
  });

  group('LlamaModelManager mmproj support', () {
    test('downloads, verifies, installs atomically, exposes projectorPath and '
        'deletes cleanly', () async {
      final requests = <http.BaseRequest>[];
      final manager = LlamaModelManager(
        root: root,
        httpClient: serverClient(recorded: requests),
      );
      addTearDown(manager.close);

      expect(await manager.projectorPath(visionModel.id), isNull);
      expect(await manager.isProjectorInstalled(visionModel.id), isFalse);

      final progress = <LlamaDownloadProgress>[];
      final installed = await manager.install(
        visionModel,
        onProgress: progress.add,
      );

      expect(requests, hasLength(2));
      expect(installed.id, visionModel.id);
      expect(installed.sizeBytes, mainBytes.length);
      expect(installed.projectorSizeBytes, projBytes.length);
      expect(installed.projectorSha256, mmproj.sha256);
      expect(installed.hasProjector, isTrue);
      expect(installed.totalSizeBytes, visionModel.totalSize);
      expect(installed.matches(visionModel), isTrue);
      expect(File(installed.path).readAsBytesSync(), mainBytes);
      expect(File(installed.projectorPath!).readAsBytesSync(), projBytes);

      expect(
        await manager.projectorPath(visionModel.id),
        installed.projectorPath,
      );
      expect(await manager.isProjectorInstalled(visionModel.id), isTrue);

      // Progress tracks combined totalSize across both files.
      expect(progress.first.totalBytes, visionModel.totalSize);
      expect(progress.last.receivedBytes, visionModel.totalSize);
      expect(progress.last.totalBytes, visionModel.totalSize);
      expect(progress.last.fraction, 1.0);

      // Deleting removes both GGUF and projector files.
      await manager.delete(visionModel.id);
      expect(await manager.isInstalled(visionModel), isFalse);
      expect(await manager.isProjectorInstalled(visionModel.id), isFalse);
      expect(await manager.projectorPath(visionModel.id), isNull);
    });

    test('rejects corrupt mmproj and leaves nothing installed', () async {
      final manager = LlamaModelManager(
        root: root,
        httpClient: serverClient(corruptProjector: true),
      );
      addTearDown(manager.close);

      await expectLater(
        manager.install(visionModel),
        throwsA(isA<LlamaChecksumException>()),
      );
      expect(await manager.installed(), isEmpty);
      expect(await manager.isProjectorInstalled(visionModel.id), isFalse);
    });

    test('resumes interrupted mmproj download with Range', () async {
      final requests = <http.BaseRequest>[];
      final manager1 = LlamaModelManager(
        root: root,
        httpClient: serverClient(failProjectorAfter: 500, recorded: requests),
      );
      addTearDown(manager1.close);

      await expectLater(
        manager1.install(visionModel),
        throwsA(isA<LlamaDownloadException>()),
      );
      // Main file is complete + 500 bytes of projector kept in .downloads.
      expect(await manager1.partialBytes(visionModel), mainBytes.length + 500);

      final manager2 = LlamaModelManager(
        root: root,
        httpClient: serverClient(recorded: requests),
      );
      addTearDown(manager2.close);
      final installed = await manager2.install(visionModel);
      expect(installed.matches(visionModel), isTrue);
      expect(requests.last.headers['Range'], 'bytes=500-');
      expect(await manager2.partialBytes(visionModel), 0);
    });

    test('checkSpace uses totalSize (main + mmproj)', () async {
      final manager = LlamaModelManager(
        root: root,
        httpClient: serverClient(),
        // Enough for mainBytes alone + margin, not enough for
        // totalSize + margin.
        freeSpace: (_) async =>
            LlamaModelManager.requiredSpace(mainBytes.length),
      );
      addTearDown(manager.close);

      await expectLater(
        manager.checkSpace(visionModel),
        throwsA(
          isA<LlamaInsufficientSpaceException>().having(
            (e) => e.requiredBytes,
            'requiredBytes',
            LlamaModelManager.requiredSpace(visionModel.totalSize),
          ),
        ),
      );
    });

    test(
      'imports main + mmproj together and rejects missing/corrupt mmproj',
      () async {
        final srcDir = Directory.systemTemp.createTempSync(
          'llama_import_mmproj_',
        );
        addTearDown(() => srcDir.deleteSync(recursive: true));
        final mainFile = File(p.join(srcDir.path, visionModel.name))
          ..writeAsBytesSync(mainBytes);
        final projFile = File(p.join(srcDir.path, mmproj.name))
          ..writeAsBytesSync(projBytes);

        final manager = LlamaModelManager(
          root: root,
          httpClient: serverClient(),
        );
        addTearDown(manager.close);

        // Missing mmproj fails cleanly without installing an incomplete model.
        final missingProj = await manager.importFiles([
          mainFile,
        ], catalog: catalog);
        expect(missingProj.models.single.status, LlamaImportStatus.failed);
        expect(await manager.isInstalled(visionModel), isFalse);

        // Both files together install atomically.
        final ok = await manager.importFiles([
          mainFile,
          projFile,
        ], catalog: catalog);
        expect(ok.models.single.status, LlamaImportStatus.installed);
        expect(await manager.isInstalled(visionModel), isTrue);
        expect(await manager.isProjectorInstalled(visionModel.id), isTrue);
      },
    );

    test('llamaProjectorDownloadUrls builds mirror and fallback URLs', () {
      final mirror = Uri.parse('https://mirror.example/models/');
      expect(llamaProjectorDownloadUrls(mmproj, mirror: mirror), [
        Uri.parse('https://mirror.example/models/llm/${mmproj.name}'),
      ]);
      expect(
        llamaProjectorDownloadUrls(
          mmproj,
          mirror: mirror,
          fallbackToDefault: true,
        ),
        [
          Uri.parse('https://mirror.example/models/llm/${mmproj.name}'),
          mmproj.url,
        ],
      );
    });
  });
}
