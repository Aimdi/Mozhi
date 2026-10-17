import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_models.dart';

void main() {
  late Directory root;
  late Directory inbox;
  late FakeModel ende;
  late FakeModel deen;
  late FakeModel enzh;
  late ModelCatalog catalog;
  late List<http.BaseRequest> requests;
  late BergamotModelManager manager;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bergamot_import_');
    inbox = Directory(p.join(root.path, 'inbox'))..createSync();
    ende = FakeModel('en', 'de');
    deen = FakeModel('de', 'en');
    enzh = FakeModel('en', 'zh', splitVocab: true);
    catalog = catalogOf([ende, deen, enzh]);
    requests = [];
    // Importing must never touch the network.
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('no network in this test', 500);
    });
    manager = BergamotModelManager(
      root: Directory(p.join(root.path, 'app')),
      httpClient: client,
    );
  });

  tearDown(() {
    expect(requests, isEmpty, reason: 'importFiles made a network request');
    root.deleteSync(recursive: true);
  });

  /// Writes [bytes] into the inbox as [name].
  File put(String name, List<int> bytes) =>
      File(p.join(inbox.path, name))..writeAsBytesSync(bytes);

  /// The published `.gz` files of [model], as downloaded by hand.
  List<File> published(FakeModel model) => [
    for (final file in model.files) put(file.entry.downloadName, file.gz),
  ];

  Directory installedDirectory(FakeModel model) => Directory(
    p.join(manager.modelsDirectory.path, model.catalog.pair, model.version),
  );

  void expectInstalled(FakeModel model) {
    for (final file in model.files) {
      expect(
        File(p.join(installedDirectory(model).path, file.name))
            .readAsBytesSync(),
        file.raw,
        reason: file.name,
      );
    }
  }

  List<File> leftovers() => [
    for (final dir in ['.staging', '.downloads'])
      if (Directory(p.join(manager.modelsDirectory.path, dir)).existsSync())
        ...Directory(p.join(manager.modelsDirectory.path, dir))
            .listSync(recursive: true)
            .whereType<File>(),
  ];

  group('CatalogFileDownload', () {
    test('names the file as published', () {
      expect(
        ende.files.first.entry.downloadName,
        'model.ende.intgemm.alphas.bin.gz',
      );
    });
  });

  group('importFiles', () {
    test('installs a model from its published files', () async {
      final files = published(ende);

      final result = await manager.importFiles(files, catalog: catalog);

      expect(result.models, hasLength(1));
      final outcome = result.models.single;
      expect(outcome.model, ende.catalog);
      expect(outcome.status, ModelImportStatus.installed);
      expect(outcome.missing, isEmpty);
      expect(outcome.damaged, isEmpty);
      expect(outcome.error, isNull);
      expect(outcome.toString(), 'ModelImportOutcome(en-de, installed)');
      expect(result.installed, [ende.catalog]);
      expect(result.unmatched, isEmpty);

      expectInstalled(ende);
      expect(await manager.isInstalled(ende.catalog), isTrue);
      final model = await manager.installedModel('en', 'de');
      expect(model?.sizeBytes, ende.catalog.installedSize);
      expect(leftovers(), isEmpty);
      // The imported files are only read.
      for (final file in files) {
        expect(file.existsSync(), isTrue);
      }
    });

    test('installs decompressed files and split vocabularies', () async {
      final files = [for (final file in enzh.files) put(file.name, file.raw)];

      final result = await manager.importFiles(files, catalog: catalog);

      expect(result.installed, [enzh.catalog]);
      expectInstalled(enzh);
      final paths = (await manager.installedModel('en', 'zh'))!.paths;
      expect(paths.sourceVocab, endsWith('srcvocab.enzh.spm'));
      expect(paths.targetVocab, endsWith('trgvocab.enzh.spm'));
    });

    test('matches names regardless of case and mixes both forms', () async {
      final [model, shortlist, vocab] = ende.files;
      final files = [
        put(model.entry.downloadName.toUpperCase(), model.gz),
        put(shortlist.name, shortlist.raw),
        put(vocab.entry.downloadName, vocab.gz),
      ];

      final result = await manager.importFiles(files, catalog: catalog);

      expect(result.installed, [ende.catalog]);
      expectInstalled(ende);
    });

    test('reports the missing files of an incomplete model', () async {
      final [model, shortlist, vocab] = deen.files;
      final files = [put(model.entry.downloadName, model.gz)];

      final result = await manager.importFiles(files, catalog: catalog);

      final outcome = result.models.single;
      expect(outcome.model, deen.catalog);
      expect(outcome.status, ModelImportStatus.incomplete);
      expect(outcome.missing, [shortlist.entry, vocab.entry]);
      expect(outcome.damaged, isEmpty);
      expect(result.installed, isEmpty);
      expect(await manager.installed(), isEmpty);
      expect(installedDirectory(deen).existsSync(), isFalse);
    });

    test('rejects a file whose SHA-256 differs', () async {
      final files = published(ende);
      final corrupt = List.of(ende.files.first.gz)..[20] ^= 0xFF;
      files.first.writeAsBytesSync(corrupt);

      final result = await manager.importFiles(files, catalog: catalog);

      final outcome = result.models.single;
      expect(outcome.status, ModelImportStatus.checksumMismatch);
      expect(outcome.missing, [ende.files.first.entry]);
      expect(outcome.damaged.map((f) => f.path), [files.first.path]);
      expect(await manager.installed(), isEmpty);
      expect(leftovers(), isEmpty);
    });

    test('rejects a truncated file and an unreadable one', () async {
      final [model, shortlist, vocab] = ende.files;
      final truncated = put(model.entry.downloadName, model.gz.sublist(0, 9));
      final missing = File(p.join(inbox.path, vocab.name));

      final result = await manager.importFiles([
        truncated,
        put(shortlist.entry.downloadName, shortlist.gz),
        missing,
      ], catalog: catalog);

      final outcome = result.models.single;
      expect(outcome.status, ModelImportStatus.checksumMismatch);
      expect(outcome.missing, [model.entry, vocab.entry]);
      expect(outcome.damaged.map((f) => f.path), [
        truncated.path,
        missing.path,
      ]);
    });

    test('lists files that belong to no model', () async {
      final notes = put('notes.txt', utf8.encode('shopping list'));
      final unknownModel = put('model.xxyy.intgemm.alphas.bin.gz', [1, 2, 3]);
      final missing = File(p.join(inbox.path, 'gone.bin'));

      final result = await manager.importFiles([
        notes,
        unknownModel,
        missing,
        ...published(ende),
      ], catalog: catalog);

      expect(result.unmatched.map((f) => f.path), [
        notes.path,
        unknownModel.path,
        missing.path,
      ]);
      expect(result.installed, [ende.catalog]);
    });

    test('finds renamed copies by size and SHA-256', () async {
      final [model, shortlist, vocab] = ende.files;
      // Same size as the shortlist download, other contents.
      final lookalike = put('lex (2).bin', List.filled(shortlist.gz.length, 7));
      final files = [
        put('model.ende.intgemm.alphas (1).bin.gz', model.gz),
        lookalike,
        put('Download', shortlist.gz),
        put('vocab copy.spm', vocab.raw),
      ];

      final result = await manager.importFiles(files, catalog: catalog);

      expect(result.installed, [ende.catalog]);
      expect(result.unmatched.map((f) => f.path), [lookalike.path]);
      expectInstalled(ende);
    });

    test('ignores duplicates and a damaged copy next to a good one', () async {
      final model = deen.files.first;
      Directory(p.join(inbox.path, 'damaged')).createSync();
      final damaged = put(
        p.join('damaged', model.entry.downloadName),
        List.filled(model.gz.length, 0),
      );
      final files = [damaged, ...published(deen), ...published(deen)];

      final result = await manager.importFiles(files, catalog: catalog);

      final outcome = result.models.single;
      expect(outcome.status, ModelImportStatus.installed);
      expect(outcome.damaged, isEmpty);
      expect(result.unmatched, isEmpty);
      expectInstalled(deen);
    });

    test('reports models that are installed already', () async {
      await manager.importFiles(published(ende), catalog: catalog);
      final before = installedDirectory(ende).statSync().modified;
      // Even a damaged copy is not read: the model is not touched.
      final files = published(ende)..first.writeAsBytesSync([1, 2, 3]);

      final result = await manager.importFiles(files, catalog: catalog);

      expect(result.models.single.status, ModelImportStatus.alreadyInstalled);
      expect(result.installed, isEmpty);
      expect(installedDirectory(ende).statSync().modified, before);
      expectInstalled(ende);
    });

    test('recognises a renamed copy of an installed model', () async {
      await manager.importFiles(published(ende), catalog: catalog);

      final result = await manager.importFiles([
        put('renamed', ende.files.first.gz),
      ], catalog: catalog);

      expect(result.models.single.status, ModelImportStatus.alreadyInstalled);
      expect(result.unmatched, isEmpty);
    });

    test(
      'installs complete directions of a mix and reports the rest',
      () async {
        final [model, shortlist, _] = ende.files;
        final files = [
          put(model.entry.downloadName, model.gz),
          ...published(deen),
          put(shortlist.entry.downloadName, shortlist.gz),
        ];

        final result = await manager.importFiles(files, catalog: catalog);

        expect(result.models.map((o) => (o.model.pair, o.status)), [
          ('de-en', ModelImportStatus.installed),
          ('en-de', ModelImportStatus.incomplete),
        ]);
        expect(result.models.last.missing, [ende.files.last.entry]);
        expect(result.installed, [deen.catalog]);
        expect((await manager.installed()).map((m) => m.pair), ['de-en']);
      },
    );

    test('replaces an older version and its partial downloads', () async {
      final old = FakeModel('en', 'de', version: 'run0', seed: 3);
      await manager.importFiles(published(old), catalog: catalogOf([old]));
      expect((await manager.installedModel('en', 'de'))?.version, 'run0');
      final partial = File(
        p.join(
          manager.modelsDirectory.path,
          '.downloads',
          'en-de',
          'run1',
          '${ende.files.first.name}.gz.part',
        ),
      )..createSync(recursive: true);

      final result = await manager.importFiles(
        published(ende),
        catalog: catalog,
      );

      expect(result.installed, [ende.catalog]);
      expect((await manager.installedModel('en', 'de'))?.version, 'run1');
      expect(
        Directory(p.join(manager.modelsDirectory.path, 'en-de'))
            .listSync()
            .map((e) => p.basename(e.path)),
        ['run1'],
      );
      expect(partial.existsSync(), isFalse);
    });

    test('reports a gzip file that decompresses to something else', () async {
      final file = ende.files.first;
      final wrong = CatalogFile(
        kind: file.kind,
        name: file.name,
        url: file.entry.url,
        size: file.entry.size,
        sha256: file.entry.sha256,
        uncompressedSize: file.entry.uncompressedSize,
        uncompressedSha256: 'a' * 64,
      );
      final model = CatalogModel(
        source: 'en',
        target: 'de',
        version: 'run1',
        files: {...ende.catalog.files, file.kind: wrong},
      );
      final files = published(ende);

      final result = await manager.importFiles(
        files,
        catalog: ModelCatalog([model]),
      );

      final outcome = result.models.single;
      expect(outcome.status, ModelImportStatus.checksumMismatch);
      expect(outcome.missing, [wrong]);
      expect(outcome.damaged.map((f) => f.path), [files.first.path]);
      expect(outcome.error, isA<ModelChecksumException>());
      expect(await manager.installed(), isEmpty);
      expect(leftovers(), isEmpty);
    });

    test('reports a model that cannot be written', () async {
      // A file where the staging directory should be.
      File(p.join(manager.modelsDirectory.path, '.staging'))
        ..createSync(recursive: true)
        ..writeAsStringSync('in the way');

      final result = await manager.importFiles(
        published(ende),
        catalog: catalog,
      );

      final outcome = result.models.single;
      expect(outcome.status, ModelImportStatus.failed);
      expect(outcome.error, isA<FileSystemException>());
      expect(result.installed, isEmpty);
    });

    group('while a download of the model is running', () {
      late Completer<void> requested;
      late Completer<int> status;
      late BergamotModelManager downloader;

      setUp(() {
        requested = Completer();
        status = Completer();
        final served = {for (final file in ende.files) file.entry.url: file.gz};
        // Holds every request until [status] says how to answer.
        downloader = BergamotModelManager(
          root: Directory(p.join(root.path, 'busy')),
          httpClient: MockClient.streaming((request, _) async {
            if (!requested.isCompleted) requested.complete();
            final code = await status.future;
            return code == 200
                ? http.StreamedResponse(Stream.value(served[request.url]!), 200)
                : http.StreamedResponse(const Stream.empty(), code);
          }),
        );
      });

      Future<ModelImportResult> importDuring(int answer) async {
        final importing = downloader.importFiles(
          published(ende),
          catalog: catalog,
        );
        // Give the import time to find the download.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        status.complete(answer);
        return await importing;
      }

      test('installs the files when the download fails', () async {
        final download = downloader.install(ende.catalog);
        await requested.future;

        final result = await importDuring(503);

        await expectLater(download, throwsA(isA<ModelDownloadException>()));
        expect(result.installed, [ende.catalog]);
        expect(await downloader.isInstalled(ende.catalog), isTrue);
      });

      test('keeps the downloaded model when the download succeeds', () async {
        final download = downloader.install(ende.catalog);
        await requested.future;

        final result = await importDuring(200);

        expect((await download).pair, 'en-de');
        expect(result.models.single.status, ModelImportStatus.alreadyInstalled);
        expect(await downloader.isInstalled(ende.catalog), isTrue);
      });
    });

    test('reports nothing for no files', () async {
      final result = await manager.importFiles(const [], catalog: catalog);
      expect(result.models, isEmpty);
      expect(result.unmatched, isEmpty);
      expect(result.installed, isEmpty);
    });
  });
}
