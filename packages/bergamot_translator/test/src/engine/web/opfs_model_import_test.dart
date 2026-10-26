import 'dart:async';
import 'dart:typed_data';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../../helpers/fake_models.dart';
import 'fake_bergamot_worker.dart';

/// A picked file: a name and its bytes (in [chunk]-sized pieces).
class _Picked implements ModelImportSource {
  new(this.name, this.bytes, {this.knownLength = true});

  @override
  final String name;
  final List<int> bytes;
  final bool knownLength;
  final int chunk = 700;
  int reads = 0;

  @override
  int? get length => knownLength ? bytes.length : null;

  @override
  Stream<List<int>> openRead() async* {
    reads++;
    for (var i = 0; i < bytes.length; i += chunk) {
      yield bytes.sublist(
        i,
        i + chunk > bytes.length ? bytes.length : i + chunk,
      );
    }
  }
}

/// A picked file whose reading fails.
class _Unreadable implements ModelImportSource {
  new(this.name, this.length);

  @override
  final String name;
  @override
  final int length;

  @override
  Stream<List<int>> openRead() => Stream.error(StateError('NotReadableError'));
}

void main() {
  late FakeBergamotWorker worker;
  late FakeModel ende;
  late FakeModel deen;
  late FakeModel enzh;
  late ModelCatalog catalog;
  late List<http.BaseRequest> requests;
  late OpfsModelManager manager;

  setUp(() {
    worker = FakeBergamotWorker();
    ende = FakeModel('en', 'de');
    deen = FakeModel('de', 'en');
    enzh = FakeModel('en', 'zh', splitVocab: true);
    catalog = catalogOf([ende, deen, enzh]);
    requests = [];
    manager = OpfsModelManager(
      channel: worker,
      // Importing must never touch the network.
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('no network in this test', 500);
      }),
      writeChunkSize: 1000,
    );
  });

  tearDown(() {
    expect(requests, isEmpty, reason: 'importSources made a request');
    // Nothing checked is left behind.
    expect(
      worker.files.keys.where(
        (path) => path.startsWith('${OpfsModelManager.importsFolder}/'),
      ),
      isEmpty,
    );
  });

  String directoryOf(FakeModel model) =>
      'models/${model.source}-${model.target}/${model.version}';

  /// The published `.gz` files of [model], as downloaded by hand.
  List<_Picked> published(FakeModel model) => [
    for (final file in model.files) _Picked(file.entry.downloadName, file.gz),
  ];

  void expectInstalled(FakeModel model) {
    for (final file in model.files) {
      expect(
        worker.files['${directoryOf(model)}/${file.name}'],
        file.raw,
        reason: file.name,
      );
    }
    expect(worker.hasManifest(directoryOf(model)), isTrue);
  }

  Future<ModelSourceImportResult> import(Iterable<ModelImportSource> files) =>
      manager.importSources(files, catalog: catalog);

  test('installs a model from its published files', () async {
    final result = await import(published(ende));

    expect(result.models.single.model, ende.catalog);
    expect(result.models.single.status, ModelImportStatus.installed);
    expect(result.installed, [ende.catalog]);
    expect(result.unmatched, isEmpty);
    expectInstalled(ende);
    expect(await manager.isInstalled(ende.catalog), isTrue);
    // Written in chunks of writeChunkSize, checked by the worker.
    expect(worker.ops, containsAll(['fingerprint', 'install', 'commit']));
    final writes = [
      for (final (op, arguments) in worker.requests)
        if (op == 'downloadWrite') (arguments['bytes']! as Uint8List).length,
    ];
    expect(writes.every((size) => size <= 1700), isTrue);
  });

  test('installs decompressed files and renamed copies', () async {
    final result = await import([
      // Decompressed, in upper case.
      _Picked(ende.files[0].name.toUpperCase(), ende.files[0].raw),
      // Renamed copies, published and decompressed (size and SHA-256).
      _Picked('download (1).gz', ende.files[1].gz),
      _Picked('vocab', ende.files[2].raw),
    ]);

    expect(result.models.single.status, ModelImportStatus.installed);
    expectInstalled(ende);
  });

  test('several models at once, files in any order', () async {
    final files = [...published(enzh), ...published(ende)]..shuffle();
    final result = await import(files);

    expect(
      [for (final outcome in result.models) outcome.model.pair],
      ['en-de', 'en-zh'],
    );
    expect(result.installed, hasLength(2));
    expectInstalled(ende);
    expectInstalled(enzh);
  });

  test('reports missing files and installs nothing', () async {
    final result = await import(published(ende).take(2));

    final outcome = result.models.single;
    expect(outcome.status, ModelImportStatus.incomplete);
    expect(outcome.missing, [ende.files[2].entry]);
    expect(worker.hasManifest(directoryOf(ende)), isFalse);
    expect(
      worker.files.keys.where((path) => path.startsWith('models/')),
      isEmpty,
    );
  });

  test('reports a damaged file by name and installs nothing', () async {
    final damaged = Uint8List.fromList(ende.files[0].gz)..[10] ^= 0xff;
    final result = await import([
      _Picked(ende.files[0].entry.downloadName, damaged),
      ...published(ende).skip(1),
    ]);

    final outcome = result.models.single;
    expect(outcome.status, ModelImportStatus.checksumMismatch);
    expect(outcome.missing, [ende.files[0].entry]);
    expect(outcome.damaged, isEmpty);
    expect(worker.hasManifest(directoryOf(ende)), isFalse);
  });

  test('a file of the wrong size is damaged without being read', () async {
    final short = _Picked(
      ende.files[0].entry.downloadName,
      ende.files[0].gz.sublist(1),
    );
    final result = await import([short, ...published(ende).skip(1)]);

    expect(result.models.single.status, ModelImportStatus.checksumMismatch);
    expect(short.reads, 0);
  });

  test('a file that grows past its catalog size is damaged', () async {
    final long = _Picked(ende.files[0].entry.downloadName, [
      ...ende.files[0].gz,
      ...ende.files[0].raw,
    ], knownLength: false);
    final result = await import([long, ...published(ende).skip(1)]);

    expect(result.models.single.status, ModelImportStatus.checksumMismatch);
  });

  test('a good copy wins over a damaged one of the same file', () async {
    final damaged = Uint8List.fromList(ende.files[0].gz)..[10] ^= 0xff;
    final result = await import([
      _Picked(ende.files[0].entry.downloadName, damaged),
      ...published(ende),
    ]);

    expect(result.models.single.status, ModelImportStatus.installed);
    expectInstalled(ende);
  });

  test('a file the worker cannot decompress is damaged', () async {
    // The right size and SHA-256 of the gzip file (a catalog that lies):
    // the worker's own check fails while installing.
    final file = ende.files[0];
    final fake = Uint8List(file.gz.length);
    final lying = CatalogModel(
      source: 'en',
      target: 'de',
      version: ende.version,
      architecture: 'tiny',
      releaseStatus: 'Release',
      files: {
        ...ende.catalog.files,
        file.kind: CatalogFile(
          kind: file.kind,
          name: file.name,
          url: file.entry.url,
          size: fake.length,
          sha256: _sha(fake),
          uncompressedSize: file.raw.length,
          uncompressedSha256: file.entry.uncompressedSha256,
        ),
      },
    );
    final result = await manager.importSources([
      _Picked(file.entry.downloadName, fake),
      ...published(ende).skip(1),
    ], catalog: ModelCatalog([lying]));

    final outcome = result.models.single;
    expect(outcome.status, ModelImportStatus.checksumMismatch);
    expect(outcome.missing.single.kind, file.kind);
    expect(outcome.error, isA<ModelChecksumException>());
    expect(
      worker.files.keys.where((path) => path.startsWith('models/')),
      isEmpty,
    );
  });

  test('an installed model is not read again', () async {
    await import(published(ende));
    final again = published(ende);
    final result = await import(again);

    expect(result.models.single.status, ModelImportStatus.alreadyInstalled);
    expect(again.every((file) => file.reads == 0), isTrue);
  });

  test('replaces another version of the pair', () async {
    final old = FakeModel('en', 'de', version: 'run0', seed: 5);
    final oldCatalog = catalogOf([old]);
    await manager.importSources(published(old), catalog: oldCatalog);
    expect(await manager.isInstalled(old.catalog), isTrue);

    final result = await import(published(ende));

    expect(result.models.single.status, ModelImportStatus.installed);
    expectInstalled(ende);
    expect(
      worker.files.keys.where((path) => path.startsWith(directoryOf(old))),
      isEmpty,
    );
  });

  test('files of no model are reported, also unreadable ones', () async {
    final result = await import([
      _Picked('notes.txt', [1, 2, 3]),
      // A catalog size, but other bytes.
      _Picked('copy.bin', Uint8List(ende.files[0].gz.length)),
      _Unreadable('other.bin', ende.files[1].gz.length),
      _Picked('nameless', [1], knownLength: false),
    ]);

    expect(result.models, isEmpty);
    expect(
      [for (final file in result.unmatched) file.name],
      ['notes.txt', 'copy.bin', 'other.bin', 'nameless'],
    );
  });

  test(
    'a renamed copy of an installed model is touched, not installed',
    () async {
      await import(published(ende));
      final result = await import([_Picked('x.gz', ende.files[0].gz)]);

      expect(result.models.single.status, ModelImportStatus.alreadyInstalled);
      expect(result.unmatched, isEmpty);
    },
  );

  test('a duplicate renamed copy is checked once', () async {
    final result = await import([
      ...published(ende),
      _Picked('again.gz', ende.files[0].gz),
    ]);

    expect(result.models.single.status, ModelImportStatus.installed);
  });

  test('storage that refuses the install fails the model', () async {
    worker.failNext['commit'] = const BergamotWorkerException(
      BergamotWorkerErrorKind.storage,
      'QuotaExceededError',
    );
    final result = await import(published(ende));

    final outcome = result.models.single;
    expect(outcome.status, ModelImportStatus.failed);
    expect(outcome.error, isA<Exception>());
    expect(worker.hasManifest(directoryOf(ende)), isFalse);
  });

  test('too little storage fails the model before writing it', () async {
    final small = OpfsModelManager(
      channel: worker,
      httpClient: MockClient((_) async => http.Response('', 500)),
      freeSpace: () async => 10,
    );
    final result = await small.importSources(published(ende), catalog: catalog);

    final outcome = result.models.single;
    expect(outcome.status, ModelImportStatus.failed);
    expect(outcome.error, isA<ModelInsufficientSpaceException>());
  });

  test('waits for a download of the same model, then reports it', () async {
    final server = FakeModelServer([ende]);
    final downloading = OpfsModelManager(
      channel: worker,
      httpClient: server.client,
    );
    final hold = Completer<void>();
    worker.holds['commit'] = hold;
    final install = downloading.install(ende.catalog);
    final imported = downloading.importSources(
      published(ende),
      catalog: catalog,
    );
    await pumpEventQueue();
    hold.complete();
    await install;
    final result = await imported;

    expect(result.models.single.status, ModelImportStatus.alreadyInstalled);
  });
}

String _sha(List<int> bytes) => '${sha256.convert(bytes)}';
