import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:tesseract_ocr/tesseract_ocr.dart';

import '../helpers/fake_tessdata.dart';

void main() {
  late Directory root;
  late FakeTessdata deu;
  late FakeTessdata eng;
  late FakeTessdata chi;
  late FakeTessdataServer server;
  late TessdataManager manager;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tessdata_manager_');
    deu = FakeTessdata('deu', seed: 1);
    eng = FakeTessdata('eng', size: 5200, seed: 2);
    chi = FakeTessdata('chi_sim', size: 3100, languages: ['zh-CN'], seed: 3);
    server = FakeTessdataServer([deu, eng, chi]);
    manager = TessdataManager(root: root, httpClient: server.client);
  });

  tearDown(() => root.deleteSync(recursive: true));

  String dataPath(String code) =>
      p.join(root.path, 'tessdata', '$code.traineddata');
  String recordPath(String code) => p.join(root.path, 'tessdata', '$code.json');
  File part(String code) =>
      File(p.join(root.path, '.downloads', '$code.traineddata.part'));

  group('install', () {
    test('verifies and installs the file with its record', () async {
      final progress = <TessdataDownloadProgress>[];
      final installed = await manager.install(
        deu.language,
        onProgress: progress.add,
      );

      expect(installed.code, 'deu');
      expect(installed.path, dataPath('deu'));
      expect(installed.sizeBytes, deu.bytes.length);
      expect(installed.sha256, deu.language.sha256);
      expect(installed.toString(), 'InstalledTessdata(deu)');
      expect(File(dataPath('deu')).readAsBytesSync(), deu.bytes);
      final record = jsonDecode(
        File(recordPath('deu')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(record, {
        'schemaVersion': 1,
        'code': 'deu',
        'size': deu.bytes.length,
        'sha256': deu.language.sha256,
      });
      expect(progress.first.receivedBytes, 0);
      expect(progress.last.receivedBytes, deu.bytes.length);
      expect(progress.last.totalBytes, deu.bytes.length);
      expect(progress.last.fraction, 1);
      expect(progress.last.language, deu.language);
      expect(manager.dataDirectory.path, p.join(root.path, 'tessdata'));
      expect(await manager.isInstalled(deu.language), isTrue);
      expect(await manager.installed(), [installed]);
      expect(await manager.totalSize(), deu.bytes.length);
      expect(part('deu').existsSync(), isFalse);
      expect(Directory(p.join(root.path, '.staging')).listSync(), isEmpty);
    });

    test('returns at once when already installed', () async {
      await manager.install(deu.language);
      final requests = server.requests.length;
      await manager.install(deu.language);
      expect(server.requests, hasLength(requests));
    });

    test('shares one download between concurrent calls', () async {
      final results = await Future.wait([
        manager.install(deu.language),
        manager.install(deu.language),
      ]);
      expect(results[0], results[1]);
      expect(server.requests, hasLength(1));
    });

    test('rejects a download whose SHA-256 differs and deletes it', () async {
      server.overrides[deu.language.url.toString()] = List.of(deu.bytes)
        ..[10] ^= 0xFF;
      await expectLater(
        manager.install(deu.language),
        throwsA(
          isA<TessdataChecksumException>()
              .having((e) => e.language, 'language', 'deu')
              .having((e) => e.toString(), 'toString', contains('SHA-256')),
        ),
      );
      expect(await manager.installed(), isEmpty);
      expect(File(dataPath('deu')).existsSync(), isFalse);
      expect(part('deu').existsSync(), isFalse);
    });

    test('rejects a download that is longer than the catalog says', () async {
      server.overrides[deu.language.url.toString()] = [...deu.bytes, 1, 2];
      await expectLater(
        manager.install(deu.language),
        throwsA(
          isA<TessdataChecksumException>().having(
            (e) => e.message,
            'message',
            contains('more than'),
          ),
        ),
      );
      expect(part('deu').existsSync(), isFalse);
    });

    test('reports HTTP errors with their status', () async {
      server.failures[deu.language.url.toString()] = 404;
      await expectLater(
        manager.install(deu.language),
        throwsA(
          isA<TessdataDownloadException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having(
                (e) => e.toString(),
                'toString',
                startsWith('TessdataDownloadException(deu: HTTP 404'),
              ),
        ),
      );
    });

    test('reports connection failures', () async {
      server.offline = true;
      await expectLater(
        manager.install(deu.language),
        throwsA(
          isA<TessdataDownloadException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    });

    test('times out a server that does not answer', () async {
      final hanging = TessdataManager(
        root: root,
        httpClient: MockClient.streaming(
          (_, _) => Completer<http.StreamedResponse>().future,
        ),
        requestTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        hanging.install(deu.language),
        throwsA(isA<TessdataDownloadException>()),
      );
    });

    test('resumes an interrupted download with a Range request', () async {
      server.cutAfter = 1000;
      await expectLater(
        manager.install(deu.language),
        throwsA(
          isA<TessdataDownloadException>().having(
            (e) => e.message,
            'message',
            contains('Connection reset'),
          ),
        ),
      );
      expect(part('deu').lengthSync(), 1000);
      expect(server.requests.last.headers['Range'], isNull);

      final progress = <int>[];
      await manager.install(
        deu.language,
        onProgress: (update) => progress.add(update.receivedBytes),
      );
      expect(server.requests.last.headers['Range'], 'bytes=1000-');
      expect(progress.first, 1000);
      expect(File(dataPath('deu')).readAsBytesSync(), deu.bytes);
    });

    test('restarts when the server ignores the Range request', () async {
      server.cutAfter = 1000;
      await expectLater(
        manager.install(deu.language),
        throwsA(isA<TessdataDownloadException>()),
      );
      server.ignoreRange = true;
      await manager.install(deu.language);
      expect(File(dataPath('deu')).readAsBytesSync(), deu.bytes);
    });

    test('verifies a complete partial download without a request', () async {
      part('deu')
        ..createSync(recursive: true)
        ..writeAsBytesSync(deu.bytes);
      await manager.install(deu.language);
      expect(server.requests, isEmpty);
      expect(await manager.isInstalled(deu.language), isTrue);
    });

    test('discards a partial download longer than the file', () async {
      part('deu')
        ..createSync(recursive: true)
        ..writeAsBytesSync([...deu.bytes, 1]);
      await manager.install(deu.language);
      expect(server.requests.single.headers['Range'], isNull);
      expect(await manager.isInstalled(deu.language), isTrue);
    });

    test('replaces an older version of the language', () async {
      final older = FakeTessdata('deu', seed: 9);
      server.overrides[deu.language.url.toString()] = older.bytes;
      await manager.install(older.language);
      expect(await manager.isInstalled(deu.language), isFalse);
      expect(
        (await manager.installedLanguage('deu'))!.sha256,
        older.language.sha256,
      );

      server.overrides.clear();
      await manager.install(deu.language);
      expect(await manager.isInstalled(deu.language), isTrue);
      expect(File(dataPath('deu')).readAsBytesSync(), deu.bytes);
    });

    test('refuses unsafe codes', () async {
      final unsafe = TessdataLanguage(
        code: '../x',
        name: 'x',
        languages: const ['x'],
        url: Uri.parse('https://example.org/x.traineddata'),
        size: 1,
        sha256: deu.language.sha256,
      );
      expect(() => manager.install(unsafe), throwsArgumentError);
      expect(() => manager.delete('../x'), throwsArgumentError);
    });
  });

  group('installed', () {
    test('lists every complete install, sorted by code', () async {
      await manager.install(eng.language);
      await manager.install(chi.language);
      expect(
        [for (final language in await manager.installed()) language.code],
        ['chi_sim', 'eng'],
      );
      expect(await manager.totalSize(), eng.bytes.length + chi.bytes.length);
      expect(await manager.installedLanguage('deu'), isNull);
    });

    test('ignores files without a valid record', () async {
      await manager.install(deu.language);
      await manager.install(eng.language);
      final fresh = TessdataManager(root: root, httpClient: server.client);
      // A truncated file, a record of another schema, an unrelated file.
      File(dataPath('deu')).writeAsBytesSync([1, 2, 3]);
      File(recordPath('eng')).writeAsStringSync('{"schemaVersion": 99}');
      File(p.join(root.path, 'tessdata', 'notes.json')).writeAsStringSync('[');
      File(dataPath('fra')).writeAsBytesSync([1]);
      expect(await fresh.installed(), isEmpty);
    });

    test('is empty without a data directory', () async {
      expect(await manager.installed(), isEmpty);
      expect(await manager.totalSize(), 0);
    });
  });

  group('delete', () {
    test('removes the file, its record and a partial download', () async {
      await manager.install(deu.language);
      part('deu')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2]);
      await manager.delete('deu');
      expect(File(dataPath('deu')).existsSync(), isFalse);
      expect(File(recordPath('deu')).existsSync(), isFalse);
      expect(part('deu').existsSync(), isFalse);
      expect(await manager.installed(), isEmpty);
    });

    test('of a language that is not installed does nothing', () async {
      await manager.delete('deu');
      expect(await manager.installed(), isEmpty);
    });
  });

  group('cleanUp', () {
    test('removes staging and data files without a record', () async {
      await manager.install(deu.language);
      File(dataPath('fra')).writeAsBytesSync([1]);
      File(p.join(root.path, '.staging', 'x.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      part('eng')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);

      await manager.cleanUp();

      expect(File(dataPath('fra')).existsSync(), isFalse);
      expect(Directory(p.join(root.path, '.staging')).existsSync(), isFalse);
      expect(File(dataPath('deu')).existsSync(), isTrue);
      expect(part('eng').existsSync(), isTrue);
    });

    test('works on an empty root', () async {
      await manager.cleanUp();
    });
  });

  group('importFiles', () {
    late Directory picked;
    late TessdataCatalog catalog;

    setUp(() {
      picked = Directory(p.join(root.path, 'picked'))..createSync();
      catalog = fakeCatalog([deu, eng, chi]);
    });

    File write(String name, List<int> bytes) =>
        File(p.join(picked.path, name))..writeAsBytesSync(bytes);

    test('installs files matched by name, ignoring case', () async {
      final result = await manager.importFiles([
        write('DEU.traineddata', deu.bytes),
        write('chi_sim.TRAINEDDATA', chi.bytes),
      ], catalog: catalog);

      expect(
        [for (final outcome in result.languages) outcome.status],
        [TessdataImportStatus.installed, TessdataImportStatus.installed],
      );
      expect(result.installed, [chi.language, deu.language]);
      expect(result.unmatched, isEmpty);
      expect(
        result.languages.first.toString(),
        'TessdataImportOutcome(chi_sim, installed)',
      );
      expect(await manager.isInstalled(deu.language), isTrue);
      expect(await manager.isInstalled(chi.language), isTrue);
      expect(File(dataPath('deu')).readAsBytesSync(), deu.bytes);
      // The picked files are only read.
      expect(File(p.join(picked.path, 'DEU.traineddata')).existsSync(), isTrue);
      expect(server.requests, isEmpty);
    });

    test('recognises a renamed copy by size and SHA-256', () async {
      final result = await manager.importFiles([
        write('eng (1).traineddata', eng.bytes),
        write('download.bin', deu.bytes),
      ], catalog: catalog);
      expect(result.installed, [deu.language, eng.language]);
    });

    test('reports a damaged file and files of no language', () async {
      final damaged = write('deu.traineddata', List.of(deu.bytes)..[0] ^= 1);
      final short = write('eng.traineddata', [1, 2, 3]);
      final other = write('photo.jpg', [1, 2, 3, 4]);
      final result = await manager.importFiles([
        damaged,
        short,
        other,
      ], catalog: catalog);

      expect(result.installed, isEmpty);
      expect(result.unmatched, [other]);
      final deuOutcome = result.languages.firstWhere(
        (outcome) => outcome.language == deu.language,
      );
      expect(deuOutcome.status, TessdataImportStatus.checksumMismatch);
      expect(deuOutcome.damaged, [damaged]);
      final engOutcome = result.languages.firstWhere(
        (outcome) => outcome.language == eng.language,
      );
      expect(engOutcome.damaged, [short]);
      expect(await manager.installed(), isEmpty);
    });

    test('a good copy wins over a damaged one of the same language', () async {
      final result = await manager.importFiles([
        write('deu.traineddata', [1, 2, 3]),
        write('deu (2).traineddata', deu.bytes),
      ], catalog: catalog);
      expect(result.languages.single.status, TessdataImportStatus.installed);
    });

    test('skips languages that are installed already', () async {
      await manager.install(deu.language);
      final result = await manager.importFiles([
        write('deu.traineddata', deu.bytes),
        write('renamed', deu.bytes),
      ], catalog: catalog);
      expect(
        result.languages.single.status,
        TessdataImportStatus.alreadyInstalled,
      );
    });

    test('waits for a running download of the same language', () async {
      final download = manager.install(deu.language);
      final result = await manager.importFiles([
        write('deu.traineddata', deu.bytes),
      ], catalog: catalog);
      await download;
      expect(
        result.languages.single.status,
        TessdataImportStatus.alreadyInstalled,
      );
    });

    test('installs the file when a running download fails', () async {
      server.failures[deu.language.url.toString()] = 500;
      final download = manager.install(deu.language);
      final result = await manager.importFiles([
        write('deu.traineddata', deu.bytes),
      ], catalog: catalog);
      await expectLater(download, throwsA(isA<TessdataDownloadException>()));
      expect(result.languages.single.status, TessdataImportStatus.installed);
    });

    test('reports a file that changed after it was verified', () async {
      final file = write('deu.traineddata', deu.bytes);
      final result = await manager.importFiles(
        _ChangingFiles(file, () => file.writeAsBytesSync([1, 2, 3])),
        catalog: catalog,
      );
      final outcome = result.languages.single;
      expect(outcome.status, TessdataImportStatus.checksumMismatch);
      expect(outcome.error, isA<TessdataChecksumException>());
      expect(outcome.damaged, [file]);
      expect(await manager.installed(), isEmpty);
    });

    test('reports files that cannot be read as unmatched', () async {
      final missing = File(p.join(picked.path, 'gone.traineddata'));
      final result = await manager.importFiles([missing], catalog: catalog);
      expect(result.unmatched, [missing]);
    });

    test('reports install failures', () async {
      // A file where the data directory must go.
      File(p.join(root.path, 'tessdata')).writeAsStringSync('x');
      final result = await manager.importFiles([
        write('deu.traineddata', deu.bytes),
      ], catalog: catalog);
      expect(result.languages.single.status, TessdataImportStatus.failed);
      expect(result.languages.single.error, isA<FileSystemException>());
    });
  });

  test('close closes only a client it created', () {
    TessdataManager(root: root).close();
    manager.close();
  });
}

/// Yields [file], then runs [change] before the import copies it.
class _ChangingFiles extends Iterable<File> {
  _ChangingFiles(this.file, this.change);

  final File file;
  final void Function() change;

  @override
  Iterator<File> get iterator => _ChangingIterator(this);
}

class _ChangingIterator implements Iterator<File> {
  _ChangingIterator(this.files);

  final _ChangingFiles files;
  var _index = -1;

  @override
  File get current => files.file;

  @override
  bool moveNext() {
    _index++;
    if (_index == 1) files.change();
    return _index == 0;
  }
}
