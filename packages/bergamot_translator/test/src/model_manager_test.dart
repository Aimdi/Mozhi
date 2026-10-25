import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:bergamot_translator/src/file_hashing.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../helpers/fake_models.dart';

void main() {
  late Directory root;
  late FakeModel ende;
  late FakeModel deen;
  late FakeModel enzh;
  late FakeModelServer server;
  late BergamotModelManager manager;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bergamot_manager_');
    ende = FakeModel('en', 'de');
    deen = FakeModel('de', 'en');
    enzh = FakeModel('en', 'zh', splitVocab: true);
    server = FakeModelServer([ende, deen, enzh]);
    manager = BergamotModelManager(root: root, httpClient: server.client);
  });

  tearDown(() => root.deleteSync(recursive: true));

  String installedPath(FakeModel model, String name) => p.join(
    root.path,
    'models',
    '${model.source}-${model.target}',
    model.version,
    name,
  );

  group('install', () {
    test('verifies, decompresses and installs every file', () async {
      final progress = <ModelDownloadProgress>[];
      final installed = await manager.install(
        ende.catalog,
        onProgress: progress.add,
      );

      expect(installed.pair, 'en-de');
      expect(installed.version, 'run1');
      for (final file in ende.files) {
        expect(
          File(installedPath(ende, file.name)).readAsBytesSync(),
          file.raw,
        );
      }
      expect(installed.sizeBytes, ende.catalog.installedSize);
      expect(progress.last.receivedBytes, ende.catalog.downloadSize);
      expect(progress.last.totalBytes, ende.catalog.downloadSize);
      expect(progress.last.fraction, 1);
      expect(progress.last.model, ende.catalog);

      final paths = installed.paths;
      expect(paths.key, 'en-de/run1');
      expect(paths.model, installedPath(ende, 'model.ende.intgemm.alphas.bin'));
      expect(paths.shortlist, installedPath(ende, 'lex.50.50.ende.s2t.bin'));
      expect(paths.sourceVocab, installedPath(ende, 'vocab.ende.spm'));
      expect(paths.targetVocab, isNull);

      final manifest = jsonDecode(
        File(installedPath(ende, BergamotModelManager.manifestName))
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(manifest['version'], 'run1');

      // Nothing is left in staging or downloads.
      final leftovers = [
        for (final dir in ['.staging', '.downloads'])
          ...Directory(p.join(root.path, 'models', dir))
              .listSync(recursive: true)
              .whereType<File>(),
      ];
      expect(leftovers, isEmpty);
    });

    test('installs split vocabularies', () async {
      final installed = await manager.install(enzh.catalog);
      expect(installed.paths.sourceVocab, endsWith('srcvocab.enzh.spm'));
      expect(installed.paths.targetVocab, endsWith('trgvocab.enzh.spm'));
    });

    test('returns at once when already installed', () async {
      await manager.install(ende.catalog);
      final requests = server.requests.length;
      final again = await manager.install(ende.catalog);
      expect(again.version, 'run1');
      expect(server.requests.length, requests);
      expect(await manager.isInstalled(ende.catalog), isTrue);
    });

    test('shares one download between concurrent calls', () async {
      final results = await Future.wait([
        manager.install(ende.catalog),
        manager.install(ende.catalog),
      ]);
      expect(results[0].pair, results[1].pair);
      expect(server.requests, hasLength(ende.files.length));
    });

    test('rejects a download whose SHA-256 differs', () async {
      final file = ende.files.first;
      final corrupt = List.of(file.gz)..[20] ^= 0xFF;
      server.overrides[file.entry.url.toString()] = corrupt;

      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelChecksumException>()
              .having((e) => e.model, 'model', 'en-de')
              .having((e) => e.toString(), 'toString', contains('SHA-256')),
        ),
      );
      expect(
        Directory(p.join(root.path, 'models', 'en-de')).existsSync(),
        isFalse,
      );
      expect(await manager.installed(), isEmpty);
      // The corrupt part is deleted, so a retry downloads it again.
      final part = File(
        p.join(
          root.path,
          'models',
          '.downloads',
          'en-de',
          'run1',
          '${file.name}.gz.part',
        ),
      );
      expect(part.existsSync(), isFalse);
      expect(
        Directory(p.join(root.path, 'models', '.staging')).listSync(),
        isEmpty,
      );
    });

    test('rejects a download that is too long', () async {
      final file = ende.files.first;
      server.overrides[file.entry.url.toString()] = [...file.gz, 1, 2, 3];
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelChecksumException>()),
      );
    });

    test('rejects a file that decompresses to something else', () async {
      final model = FakeModel('de', 'en');
      final file = model.files.first;
      final entry = CatalogFile(
        kind: file.kind,
        name: file.name,
        url: file.entry.url,
        size: file.entry.size,
        sha256: file.entry.sha256,
        uncompressedSize: file.entry.uncompressedSize,
        uncompressedSha256: 'a' * 64,
      );
      final catalog = CatalogModel(
        source: 'de',
        target: 'en',
        version: 'run1',
        files: {...model.catalog.files, file.kind: entry},
      );
      await expectLater(
        manager.install(catalog),
        throwsA(
          isA<ModelChecksumException>().having(
            (e) => e.message,
            'message',
            contains('decompressed'),
          ),
        ),
      );
      expect(await manager.installed(), isEmpty);
    });

    test('rejects a verified download that is not gzip', () async {
      final model = FakeModel('de', 'en');
      final file = model.files.first;
      final notGzip = utf8.encode('definitely not gzip data');
      server.overrides[file.entry.url.toString()] = notGzip;
      final entry = CatalogFile(
        kind: file.kind,
        name: file.name,
        url: file.entry.url,
        size: notGzip.length,
        sha256: _sha(notGzip),
        uncompressedSize: 10,
        uncompressedSha256: 'b' * 64,
      );
      final catalog = CatalogModel(
        source: 'de',
        target: 'en',
        version: 'run1',
        files: {...model.catalog.files, file.kind: entry},
      );
      await expectLater(
        manager.install(catalog),
        throwsA(isA<ModelChecksumException>()),
      );
    });

    test('reports HTTP errors', () async {
      server.failures[ende.files.last.entry.url.toString()] = 503;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.toString(), 'toString', contains('503')),
        ),
      );
      expect(await manager.installed(), isEmpty);
    });

    test('reports connection failures', () async {
      final failing = BergamotModelManager(
        root: root,
        httpClient: _ThrowingClient(),
      );
      await expectLater(
        failing.install(ende.catalog),
        throwsA(isA<ModelDownloadException>()),
      );
    });

    test('resumes an interrupted download with a Range request', () async {
      server.cutAfter = 1000;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelDownloadException>()),
      );
      final installed = await manager.install(ende.catalog);
      expect(installed.pair, 'en-de');
      final model = ende.files.first;
      expect(
        File(installedPath(ende, model.name)).readAsBytesSync(),
        model.raw,
      );
      expect(server.requests.last.headers['Range'], isNull);
      expect(
        server.requests.where((r) => r.headers['Range'] == 'bytes=1000-'),
        hasLength(1),
      );
    });

    test('restarts when the server ignores the Range request', () async {
      server.cutAfter = 1000;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(isA<ModelDownloadException>()),
      );
      server.ignoreRange = true;
      final installed = await manager.install(ende.catalog);
      expect(
        File(installed.paths.model).readAsBytesSync(),
        ende.files.first.raw,
      );
    });

    test('uses a complete part file without downloading it again', () async {
      final file = ende.files.first;
      File(
          p.join(
            root.path,
            'models',
            '.downloads',
            'en-de',
            'run1',
            '${file.name}.gz.part',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsBytesSync(file.gz);
      await manager.install(ende.catalog);
      expect(
        server.requests.map((r) => r.url),
        isNot(contains(file.entry.url)),
      );
    });

    test('discards a part file longer than the file', () async {
      final file = ende.files.first;
      File(
          p.join(
            root.path,
            'models',
            '.downloads',
            'en-de',
            'run1',
            '${file.name}.gz.part',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(file.gz.length + 5, 1));
      final installed = await manager.install(ende.catalog);
      expect(File(installed.paths.model).readAsBytesSync(), file.raw);
    });

    test('replaces an older version atomically', () async {
      await manager.install(ende.catalog);
      final newer = FakeModel('en', 'de', version: 'run2', seed: 7);
      final newServer = FakeModelServer([newer]);
      final updater = BergamotModelManager(
        root: root,
        httpClient: newServer.client,
      );

      final installed = await updater.install(newer.catalog);
      expect(installed.version, 'run2');
      expect(
        Directory(p.join(root.path, 'models', 'en-de'))
            .listSync()
            .map((e) => p.basename(e.path)),
        ['run2'],
      );
      expect(await updater.installed(), hasLength(1));
    });

    test('reinstalling the same version over a broken install', () async {
      // A directory without a valid manifest is not an install...
      final broken = Directory(installedPath(ende, ''))
        ..createSync(recursive: true);
      File(p.join(broken.path, 'junk')).writeAsStringSync('x');
      expect(await manager.installed(), isEmpty);
      // ...and is replaced by a real one.
      final installed = await manager.install(ende.catalog);
      expect(File(p.join(installed.directory, 'junk')).existsSync(), isFalse);
    });

    test('rejects unsafe pairs', () async {
      final evil = CatalogModel(
        source: 'en',
        target: 'de',
        version: 'run1',
        files: ende.catalog.files,
      );
      expect(evil.pair, 'en-de');
      expect(() => manager.delete('..', 'x'), throwsArgumentError);
    });
  });

  group('installed', () {
    test('lists complete installs only, sorted by pair', () async {
      await manager.install(ende.catalog);
      await manager.install(deen.catalog);
      // A model directory with a missing file is ignored.
      Directory(p.join(root.path, 'models', 'en-fr', 'x'))
          .createSync(recursive: true);
      File(p.join(root.path, 'models', 'en-fr', 'x', 'manifest.json'))
          .writeAsStringSync(
            jsonEncode({
              'schemaVersion': 1,
              'source': 'en',
              'target': 'fr',
              'version': 'x',
              'files': {
                'model': {'name': 'model.bin', 'size': 3},
              },
            }),
          );

      final fresh = BergamotModelManager(root: root);
      addTearDown(fresh.close);
      final installed = await fresh.installed();
      expect(installed.map((m) => m.pair), ['de-en', 'en-de']);
      expect((await fresh.installedModel('de', 'en'))?.version, 'run1');
      expect(await fresh.installedModel('en', 'fr'), isNull);
      expect(
        await fresh.totalSize(),
        ende.catalog.installedSize + deen.catalog.installedSize,
      );
    });

    test('ignores manifests that do not match their directory', () async {
      final installed = await manager.install(ende.catalog);
      final manifest = File(
        p.join(installed.directory, BergamotModelManager.manifestName),
      );
      final json =
          jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
      manifest.writeAsStringSync(jsonEncode({...json, 'version': 'other'}));
      expect(await BergamotModelManager(root: root).installed(), isEmpty);
      manifest.writeAsStringSync('not json');
      expect(await BergamotModelManager(root: root).installed(), isEmpty);
    });

    test('is empty without a models directory', () async {
      expect(await manager.installed(), isEmpty);
      expect(await manager.totalSize(), 0);
    });
  });

  group('delete', () {
    test('removes every version and partial download of a pair', () async {
      await manager.install(ende.catalog);
      await manager.install(deen.catalog);
      Directory(p.join(root.path, 'models', '.downloads', 'en-de', 'old'))
          .createSync(recursive: true);

      await manager.delete('en', 'de');

      expect((await manager.installed()).map((m) => m.pair), ['de-en']);
      expect(
        Directory(p.join(root.path, 'models', 'en-de')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, 'models', '.downloads', 'en-de'))
            .existsSync(),
        isFalse,
      );
    });

    test('is a no-op for pairs that are not installed', () async {
      await manager.delete('en', 'fr');
      expect(await manager.installed(), isEmpty);
    });
  });

  test('cleanUp removes staging and trash but keeps downloads', () async {
    for (final dir in ['.staging/a', '.trash/b', '.downloads/en-de/run1']) {
      Directory(p.join(root.path, 'models', dir)).createSync(recursive: true);
    }
    await manager.cleanUp();
    expect(
      Directory(p.join(root.path, 'models', '.staging')).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(root.path, 'models', '.trash')).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(root.path, 'models', '.downloads', 'en-de', 'run1'))
          .existsSync(),
      isTrue,
    );
  });

  group('mirror', () {
    final mirror = Uri.parse('https://mirror.test/models/');

    /// Serves every file of [model] at its mirror URL.
    void mirrorAll(FakeModel model) {
      for (final file in model.files) {
        server.overrides[bergamotMirrorUrl(
              mirror,
              model.catalog,
              file.entry,
            ).toString()] =
            file.gz;
      }
    }

    List<String> hosts() => [
      for (final request in server.requests) request.url.host,
    ];

    test('downloads every file from the mirror', () async {
      mirrorAll(ende);
      manager.mirror = mirror;
      final installed = await manager.install(ende.catalog);
      expect(installed.version, 'run1');
      expect(hosts(), everyElement('mirror.test'));
      expect(
        server.requests.first.url.path,
        startsWith('/models/bergamot/en-de/run1/'),
      );
      expect(await manager.isInstalled(ende.catalog), isTrue);
    });

    test('a file the mirror lacks fails, naming the mirror', () async {
      manager.mirror = mirror;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.mirror, 'mirror', mirror)
              .having((e) => e.message, 'message', contains('mirror.test')),
        ),
      );
      // Never the default host without the fallback.
      expect(hosts(), everyElement('mirror.test'));
      expect(await manager.installed(), isEmpty);
    });

    test('falls back to the catalog URL when allowed', () async {
      manager
        ..mirror = mirror
        ..fallbackToDefault = true;
      final installed = await manager.install(ende.catalog);
      expect(installed.pair, 'en-de');
      expect(hosts(), [
        for (final _ in ende.files) ...['mirror.test', 'models.test'],
      ]);
    });

    test('falls back when the mirror cannot be reached', () async {
      final client = _MirrorDownClient(server.client);
      final failing = BergamotModelManager(root: root, httpClient: client)
        ..mirror = mirror
        ..fallbackToDefault = true;
      await failing.install(ende.catalog);
      expect(hosts(), everyElement('models.test'));
      expect(client.refused, ende.files.length);
    });

    test('reports a mirror that cannot be reached', () async {
      final failing = BergamotModelManager(
        root: root,
        httpClient: _MirrorDownClient(server.client),
      )..mirror = mirror;
      await expectLater(
        failing.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.mirror, 'mirror', mirror),
        ),
      );
    });

    test('rejects a file from the mirror that differs, naming it', () async {
      mirrorAll(ende);
      final file = ende.files.first;
      server.overrides[bergamotMirrorUrl(
        mirror,
        ende.catalog,
        file.entry,
      ).toString()] = List.of(file.gz)
        ..[10] ^= 0xFF;
      manager
        ..mirror = mirror
        // A mismatch is not a missing file: no fallback.
        ..fallbackToDefault = true;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelChecksumException>()
              .having((e) => e.mirror, 'mirror', mirror)
              .having(
                (e) => e.toString(),
                'toString',
                contains('from the mirror https://mirror.test/models/'),
              ),
        ),
      );
      expect(hosts(), everyElement('mirror.test'));
      expect(await manager.installed(), isEmpty);
    });

    test('rejects a mirror that sends more than the file', () async {
      mirrorAll(ende);
      final file = ende.files.first;
      server.overrides[bergamotMirrorUrl(
        mirror,
        ende.catalog,
        file.entry,
      ).toString()] = [
        ...file.gz,
        1,
        2,
        3,
      ];
      manager.mirror = mirror;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelChecksumException>()
              .having((e) => e.mirror, 'mirror', mirror)
              .having((e) => e.message, 'message', contains('more than')),
        ),
      );
    });

    test('resumes a download from the default host at the mirror', () async {
      server.cutAfter = 1000;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>().having(
            (e) => e.mirror,
            'mirror',
            isNull,
          ),
        ),
      );
      mirrorAll(ende);
      manager.mirror = mirror;
      await manager.install(ende.catalog);
      expect(server.requests[1].url.host, 'mirror.test');
      expect(server.requests[1].headers['Range'], 'bytes=1000-');
    });

    test('an interrupted mirror download names the mirror', () async {
      mirrorAll(ende);
      server.cutAfter = 1000;
      manager.mirror = mirror;
      await expectLater(
        manager.install(ende.catalog),
        throwsA(
          isA<ModelDownloadException>()
              .having((e) => e.mirror, 'mirror', mirror)
              .having((e) => e.message, 'message', contains('mirror.test')),
        ),
      );
    });
  });

  test('value objects', () async {
    final installed = await manager.install(ende.catalog);
    expect(installed.toString(), 'InstalledModel(en-de, run1)');
    final paths = installed.paths;
    expect(paths, installed.paths);
    expect(paths.hashCode, installed.paths.hashCode);
    expect(paths.toString(), 'ModelPaths(en-de/run1)');
    expect(
      paths ==
          const ModelPaths(key: 'x', model: '', shortlist: '', sourceVocab: ''),
      isFalse,
    );
  });

  test('close only closes a client it created', () {
    BergamotModelManager(root: root).close();
    manager.close();
  });

  group('free space', () {
    BergamotModelManager spaced(int? free) => BergamotModelManager(
      root: root,
      httpClient: server.client,
      freeSpace: (_) async => free,
    );

    int needed(FakeModel model) =>
        model.catalog.downloadSize + model.catalog.installedSize;

    test('the margin is 5 %, at least 50 MiB', () {
      expect(BergamotModelManager.requiredSpace(1), 1 + (50 << 20));
      const large = 2 << 30;
      expect(BergamotModelManager.requiredSpace(large), large + large ~/ 20);
    });

    test('needs room for the downloads and the decompressed files', () async {
      final tight = BergamotModelManager.requiredSpace(needed(ende)) - 1;
      await expectLater(
        spaced(tight).install(ende.catalog),
        throwsA(
          isA<ModelInsufficientSpaceException>()
              .having((e) => e.model, 'model', 'en-de')
              .having((e) => e.availableBytes, 'availableBytes', tight)
              .having(
                (e) => e.requiredBytes,
                'requiredBytes',
                BergamotModelManager.requiredSpace(needed(ende)),
              )
              .having(
                (e) => e.toString(),
                'toString',
                startsWith('ModelInsufficientSpaceException(en-de'),
              ),
        ),
      );
      expect(server.requests, isEmpty);
      final installed = await spaced(tight + 1).install(ende.catalog);
      expect(installed.pair, 'en-de');
    });

    test('downloads when the free space is unknown or fails', () async {
      expect((await spaced(null).install(ende.catalog)).pair, 'en-de');
      final failing = BergamotModelManager(
        root: root,
        httpClient: server.client,
        freeSpace: (_) async => throw const FileSystemException('statfs'),
      );
      expect((await failing.install(deen.catalog)).pair, 'de-en');
    });

    test('an import needs room for the decompressed files', () async {
      final picked = Directory(p.join(root.path, 'picked'))..createSync();
      final files = [
        for (final file in ende.files)
          File(p.join(picked.path, '${file.name}.gz'))
            ..writeAsBytesSync(file.gz),
      ];
      final result = await spaced(10)
          .importFiles(files, catalog: ModelCatalog([ende.catalog]));
      expect(result.models.single.status, ModelImportStatus.failed);
      expect(
        result.models.single.error,
        isA<ModelInsufficientSpaceException>(),
      );
    });
  });

  test('hashes and decompresses inline as in the background', () async {
    final inline = BergamotModelManager(
      root: root,
      httpClient: server.client,
      hashing: const FileHashing.inline(),
    );
    expect((await inline.install(ende.catalog)).pair, 'en-de');
  });
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

class _ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(const SocketException('No network'));
}

/// Refuses every request to `mirror.test` as an unreachable host would;
/// others go to [_inner].
class _MirrorDownClient extends http.BaseClient {
  new(this._inner);

  final http.Client _inner;
  int refused = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.host == 'mirror.test') {
      refused++;
      return Future.error(const SocketException('Connection refused'));
    }
    return _inner.send(request);
  }
}
