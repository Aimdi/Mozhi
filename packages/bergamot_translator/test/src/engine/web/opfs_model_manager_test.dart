import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../../helpers/fake_models.dart';
import 'fake_bergamot_worker.dart';

void main() {
  late FakeBergamotWorker worker;
  late FakeModel ende;
  late FakeModel enzh;
  late FakeModel deen;
  late FakeModelServer server;
  late OpfsModelManager manager;
  late int persistRequests;

  setUp(() {
    worker = FakeBergamotWorker();
    ende = FakeModel('en', 'de');
    enzh = FakeModel('en', 'zh', splitVocab: true);
    deen = FakeModel('de', 'en');
    server = FakeModelServer([ende, enzh, deen]);
    persistRequests = 0;
    manager = OpfsModelManager(
      channel: worker,
      httpClient: server.client,
      writeChunkSize: 1500,
      requestPersistence: () async {
        persistRequests++;
        return true;
      },
    );
  });

  String directoryOf(FakeModel model) =>
      'models/${model.source}-${model.target}/${model.version}';

  group('install', () {
    test('downloads, verifies and installs every file', () async {
      final progress = <ModelDownloadProgress>[];
      final installed = await manager.install(
        ende.catalog,
        onProgress: progress.add,
      );

      expect(installed.pair, 'en-de');
      expect(installed.version, 'run1');
      expect(installed.directory, directoryOf(ende));
      for (final file in ende.files) {
        expect(worker.files['${directoryOf(ende)}/${file.name}'], file.raw);
      }
      expect(installed.sizeBytes, ende.catalog.installedSize);
      expect(installed.paths.key, 'en-de/run1');
      expect(
        installed.paths.model,
        '${directoryOf(ende)}/model.ende.intgemm.alphas.bin',
      );
      expect(installed.paths.targetVocab, isNull);
      expect(progress.last.receivedBytes, ende.catalog.downloadSize);
      expect(progress.last.totalBytes, ende.catalog.downloadSize);
      // The manifest comes last, and the downloads are gone.
      expect(worker.ops.last, 'list');
      expect(worker.ops, contains('commit'));
      expect(
        worker.files.keys.where((path) => path.startsWith('.downloads/')),
        isEmpty,
      );
      expect(await manager.isInstalled(ende.catalog), isTrue);
      expect(await manager.totalSize(), ende.catalog.installedSize);
    });

    test('writes in chunks of writeChunkSize', () async {
      await manager.install(ende.catalog);
      final writes = [
        for (final (op, arguments) in worker.requests)
          if (op == 'downloadWrite') (arguments['bytes']! as Uint8List).length,
      ];
      expect(writes.where((length) => length > 1500 + 1000), isEmpty);
      expect(
        writes.fold(0, (sum, length) => sum + length),
        ende.catalog.downloadSize,
      );
    });

    test('split vocabularies get both paths', () async {
      final installed = await manager.install(enzh.catalog);
      expect(installed.paths.sourceVocab, endsWith('srcvocab.enzh.spm'));
      expect(installed.paths.targetVocab, endsWith('trgvocab.enzh.spm'));
    });

    test('asks to keep the storage until the browser agrees', () async {
      var granted = false;
      manager = OpfsModelManager(
        channel: worker,
        httpClient: server.client,
        requestPersistence: () async {
          persistRequests++;
          return granted;
        },
      );
      await manager.install(ende.catalog);
      expect(persistRequests, 1);
      granted = true;
      await manager.install(enzh.catalog);
      await manager.install(deen.catalog);
      expect(persistRequests, 2);
    });

    test('a failing persistence request does not stop the download', () async {
      manager = OpfsModelManager(
        channel: worker,
        httpClient: server.client,
        requestPersistence: () => Future.error(StateError('no')),
      );
      expect((await manager.install(ende.catalog)).pair, 'en-de');
    });

    test('returns the installed model without downloading again', () async {
      await manager.install(ende.catalog);
      server.requests.clear();
      final again = await manager.install(ende.catalog);
      expect(again.version, 'run1');
      expect(server.requests, isEmpty);
    });

    test('concurrent installs of a model share one download', () async {
      final results = await Future.wait([
        manager.install(ende.catalog),
        manager.install(ende.catalog),
      ]);
      expect(results[0].pair, results[1].pair);
      expect(server.requests, hasLength(ende.files.length));
    });

    test('a new version replaces the old one', () async {
      await manager.install(ende.catalog);
      final next = FakeModel('en', 'de', version: 'run2', seed: 7);
      server = FakeModelServer([next]);
      manager = OpfsModelManager(channel: worker, httpClient: server.client);
      final installed = await manager.install(next.catalog);
      expect(installed.version, 'run2');
      expect(worker.hasManifest(directoryOf(ende)), isFalse);
      expect(
        worker.files.keys.where((path) => path.startsWith(directoryOf(ende))),
        isEmpty,
      );
      expect(await manager.installed(), hasLength(1));
    });

    test('resumes an interrupted download with Range', () async {
      final model = ende.files.first;
      server.cutAfter = 1200;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelDownloadException>()),
      );
      final part = '.downloads/en-de/run1/${model.name}.gz.part';
      expect(worker.files[part], hasLength(1200));
      expect(worker.ops.where((op) => op == 'downloadClose'), isNotEmpty);

      server.requests.clear();
      await manager.install(ende.catalog);
      expect(server.requests.first.headers['Range'], 'bytes=1200-');
      expect(worker.files['${directoryOf(ende)}/${model.name}'], model.raw);
    });

    test('starts over when the server ignores Range', () async {
      final model = ende.files.first;
      server.cutAfter = 1200;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelDownloadException>()),
      );
      server.ignoreRange = true;
      await manager.install(ende.catalog);
      expect(worker.files['${directoryOf(ende)}/${model.name}'], model.raw);
    });

    test('a complete partial download goes straight to the checks', () async {
      final model = ende.files.first;
      final part = '.downloads/en-de/run1/${model.name}.gz.part';
      worker.files[part] = model.gz;
      await manager.install(ende.catalog);
      expect(
        server.requests.where((request) => request.url == model.entry.url),
        isEmpty,
      );
      expect(worker.files['${directoryOf(ende)}/${model.name}'], model.raw);
    });

    test('a partial download longer than the file starts over', () async {
      final model = ende.files.first;
      final part = '.downloads/en-de/run1/${model.name}.gz.part';
      worker.files[part] = Uint8List(model.gz.length + 5);
      await manager.install(ende.catalog);
      expect(worker.files['${directoryOf(ende)}/${model.name}'], model.raw);
      final request = server.requests.firstWhere(
        (request) => request.url == model.entry.url,
      );
      expect(request.headers['Range'], isNull);
    });

    test(
      'a corrupted download fails the checksum and installs nothing',
      () async {
        final model = ende.files.first;
        final corrupted = Uint8List.fromList(model.gz);
        corrupted[corrupted.length ~/ 2] ^= 0xFF;
        server.overrides[model.entry.url.toString()] = corrupted;
        await expectLater(
          manager.install(ende.catalog),
          throwsA(
            isA<ModelChecksumException>().having(
              (error) => error.model,
              'model',
              'en-de',
            ),
          ),
        );
        expect(worker.hasManifest(directoryOf(ende)), isFalse);
        expect(await manager.installed(), isEmpty);
      },
    );

    test('more bytes than the catalog says fail the checksum', () async {
      final model = ende.files.first;
      server.overrides[model.entry.url.toString()] = [...model.gz, 1, 2, 3];
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelChecksumException>()),
      );
      expect(
        worker.files.keys.where((path) => path.endsWith('.gz.part')),
        isEmpty,
      );
    });

    test('an HTTP error is a ModelDownloadException with the status', () async {
      server.failures[ende.files.first.entry.url.toString()] = 503;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });

    test('a connection failure is a ModelDownloadException', () async {
      manager = OpfsModelManager(
        channel: worker,
        httpClient: MockClient(
          (_) => Future.error(const SocketException('no route')),
        ),
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>().having(
            (error) => error.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    });

    test('downloads from the mirror, falling back to the catalog', () async {
      final mirror = Uri.parse('https://mirror.test/models/');
      final requested = <Uri>[];
      final client = MockClient.streaming((request, body) {
        requested.add(request.url);
        if (request.url.host == 'mirror.test') {
          return Future.value(http.StreamedResponse(const Stream.empty(), 404));
        }
        return server.client.send(http.Request('GET', request.url));
      });
      manager = OpfsModelManager(channel: worker, httpClient: client)
        ..mirror = mirror
        ..fallbackToDefault = true;
      await manager.install(ende.catalog);
      expect(requested.first.host, 'mirror.test');
      expect(
        requested.first.path,
        '/models/bergamot/en-de/run1/${ende.files.first.entry.url.pathSegments.last}',
      );
      expect(requested[1], ende.files.first.entry.url);
    });

    test('a mirror without fallback fails with its status', () async {
      final client = MockClient((request) async => http.Response('', 404));
      manager = OpfsModelManager(channel: worker, httpClient: client)
        ..mirror = Uri.parse('https://mirror.test/');
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>()
              .having((error) => error.statusCode, 'statusCode', 404)
              .having(
                (error) => error.mirror,
                'mirror',
                Uri.parse('https://mirror.test/'),
              ),
        ),
      );
    });

    test('a mirror sending a bad file fails the checksum naming it', () async {
      final mirror = Uri.parse('https://mirror.test/');
      final client = MockClient(
        (request) async => http.Response.bytes([1, 2, 3], 200),
      );
      manager = OpfsModelManager(channel: worker, httpClient: client)
        ..mirror = mirror;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelChecksumException>().having(
            (error) => error.mirror,
            'mirror',
            mirror,
          ),
        ),
      );
    });

    test('storage errors become FileSystemException', () async {
      worker.failNext['downloadWrite'] = const BergamotWorkerException(
        BergamotWorkerErrorKind.storage,
        'QuotaExceededError: full',
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('QuotaExceededError'),
          ),
        ),
      );
    });

    test('a browser without sync access is unsupported', () async {
      worker.failNext['downloadOpen'] = const BergamotWorkerException(
        BergamotWorkerErrorKind.unsupported,
        'no sync access',
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('engine and protocol errors become BergamotEngineException', () async {
      worker.failNext['commit'] = const BergamotWorkerException(
        BergamotWorkerErrorKind.protocol,
        'bad',
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<BergamotEngineException>()),
      );
    });

    test('a storage failure while listing is a FileSystemException', () async {
      worker.failNext['list'] = const BergamotWorkerException(
        BergamotWorkerErrorKind.storage,
        'gone',
      );
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a model the browser did not keep fails', () async {
      worker.after['commit'] = () =>
          worker.files.remove('${directoryOf(ende)}/manifest.json');
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('installed', () {
    test('skips manifests this manager did not write', () async {
      await manager.install(ende.catalog);
      worker.files['models/xx-yy/v1/manifest.json'] = Uint8List.fromList(
        '{"source": "xx", "target": "yy", "version": "v1", "files": {}}'
            .codeUnits,
      );
      worker.files['models/aa-bb/v1/manifest.json'] = Uint8List.fromList(
        '{"source": "aa", "target": "bb", "version": "v2", "files": {}}'
            .codeUnits,
      );
      worker.files['models/cc-dd/v1/manifest.json'] = Uint8List.fromList(
        '{"source": "cc", "target": "dd", "version": "v1", "files": '
                '{"nonsense": {"name": "x"}}}'
            .codeUnits,
      );
      manager = OpfsModelManager(channel: worker, httpClient: server.client);
      expect(
        [for (final model in await manager.installed()) model.pair],
        ['en-de'],
      );
    });

    test('is cached until something changes', () async {
      await manager.installed();
      await manager.installed();
      expect(worker.ops.where((op) => op == 'list'), hasLength(1));
    });
  });

  group('delete', () {
    test('removes the model and its downloads', () async {
      await manager.install(ende.catalog);
      worker.files['.downloads/en-de/run9/x.gz.part'] = Uint8List(3);
      await manager.delete('en', 'de');
      expect(worker.files, isEmpty);
      expect(await manager.installed(), isEmpty);
    });
  });

  test('cleanUp removes incomplete installs and never throws', () async {
    worker.files['models/en-de/run1/model.bin'] = Uint8List(3);
    await manager.cleanUp();
    expect(worker.files, isEmpty);
    worker.failNext['cleanUp'] = const BergamotWorkerException(
      BergamotWorkerErrorKind.storage,
      'no',
    );
    await manager.cleanUp();
  });

  test('importFiles is not available', () async {
    await expectLater(
      manager.importFiles([File('x')], catalog: catalogOf([ende])),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('close leaves the client alone', () {
    var closed = false;
    final client = MockClient((_) async => http.Response('', 200));
    OpfsModelManager(
      channel: worker,
      httpClient: _ClosingClient(client, () => closed = true),
    ).close();
    expect(closed, isFalse);
  });
}

class _ClosingClient extends http.BaseClient {
  new(this._inner, this._onClose);

  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => _onClose();
}
