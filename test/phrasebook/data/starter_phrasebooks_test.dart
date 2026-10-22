import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/phrasebook/data/default_phrasebook.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/settings/models/model_source.dart';

import '../starter_fixtures.dart';

void main() {
  late MemoryStore store;
  final bytes = starterPackBytes(starterPackJson());
  final info = starterInfo(bytes);

  setUp(() => store = MemoryStore());

  StarterPhrasebooks starter(
    http.Client client, {
    List<Uri> Function(StarterPhrasebookInfo pack)? urls,
  }) => StarterPhrasebooks(
    catalog: StarterPhrasebookCatalog([info]),
    store: store,
    httpClient: client,
    downloadUrls: urls,
    clock: () => DateTime(2026, 10, 22, 12),
  );

  test('installs a pack once, checks it and reads it back', () async {
    final requested = <Uri>[];
    final packs = starter(
      MockClient((request) async {
        requested.add(request.url);
        return http.Response.bytes(bytes, 200);
      }),
    );
    final changes = <void>[];
    packs.changes.listen(changes.add);
    final progress = <double>[];
    await Future.wait([
      packs.install(info, onProgress: progress.add),
      packs.install(info),
    ]);
    expect(requested, [info.url]);
    expect(progress.first, 0);
    expect(progress.last, 1);
    await pumpEventQueue();
    expect(changes, hasLength(1));

    final installed = await packs.installed();
    expect(installed.single.id, 'pt');
    expect(installed.single.phrases, 3);
    expect(installed.single.installedAt, DateTime(2026, 10, 22, 12));
    final pack = await packs.load('pt');
    expect(pack!.phrases, hasLength(3));
    expect(pack.attribution, contains('Wikivoyage'));

    // Installed already: no request.
    await packs.install(info);
    expect(requested, hasLength(1));

    // A new repository reads it from the store.
    final again = starter(MockClient((_) async => http.Response('', 500)));
    expect((await again.load('pt'))!.revision, 1234);
    expect(await again.load('xx'), isNull);
  });

  test('a file that does not match is refused and nothing is stored', () async {
    final tampered = starterPackBytes(starterPackJson(revision: 99));
    final packs = starter(
      MockClient((_) async => http.Response.bytes(tampered, 200)),
    );
    await expectLater(
      packs.install(info),
      throwsA(isA<StarterPhrasebookChecksumException>()),
    );
    expect(store.values, isEmpty);
    expect(await packs.installed(), isEmpty);
  });

  test('a file larger than the catalogue says is cut off', () async {
    final packs = starter(
      MockClient((_) async => http.Response.bytes([...bytes, ...bytes], 200)),
    );
    await expectLater(
      packs.install(info),
      throwsA(
        isA<StarterPhrasebookChecksumException>().having(
          (e) => e.toString(),
          'toString',
          contains('more than'),
        ),
      ),
    );
  });

  test('a matching file that is not a pack is refused', () async {
    final notPack = starterPackBytes({'format': 'something else'});
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog(const []),
      store: store,
      httpClient: MockClient((_) async => http.Response.bytes(notPack, 200)),
    );
    await expectLater(
      packs.install(starterInfo(notPack)),
      throwsA(isA<StarterPhrasebookChecksumException>()),
    );
    // Another pack's file under this id is refused too.
    final other = starterPackBytes(starterPackJson(id: 'es'));
    final packs2 = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog(const []),
      store: store,
      httpClient: MockClient((_) async => http.Response.bytes(other, 200)),
    );
    await expectLater(
      packs2.install(starterInfo(other)),
      throwsA(isA<StarterPhrasebookChecksumException>()),
    );
  });

  test('a server error tries the next URL; the last error is thrown', () async {
    final mirror = Uri.parse('https://mirror.example/phrasebooks/pt.json.gz');
    final requested = <Uri>[];
    final packs = starter(
      MockClient((request) async {
        requested.add(request.url);
        return request.url == mirror
            ? http.Response('missing', 404)
            : http.Response.bytes(bytes, 200);
      }),
      urls: (pack) => [mirror, pack.url],
    );
    await packs.install(info);
    expect(requested, [mirror, info.url]);

    final failing = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: MemoryStore(),
      httpClient: MockClient((_) async => http.Response('', 503)),
      downloadUrls: (pack) => [mirror, pack.url],
    );
    await expectLater(
      failing.install(info),
      throwsA(
        isA<StarterPhrasebookDownloadException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.packId, 'packId', 'pt')
            .having(
              (e) => e.toString(),
              'toString',
              startsWith('StarterPhrasebookDownloadException(pt'),
            ),
      ),
    );
  });

  test('a connection error is a download error', () async {
    final packs = starter(
      MockClient((_) async => throw http.ClientException('offline')),
    );
    await expectLater(
      packs.install(info),
      throwsA(isA<StarterPhrasebookDownloadException>()),
    );
    final broken = starter(
      MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          Stream<List<int>>.error(http.ClientException('cut')),
          200,
        ),
      ),
    );
    await expectLater(
      broken.install(info),
      throwsA(isA<StarterPhrasebookDownloadException>()),
    );
  });

  test('without a client or URLs nothing is downloaded', () async {
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog([info]),
      store: store,
    );
    await expectLater(
      packs.install(info),
      throwsA(isA<StarterPhrasebookDownloadException>()),
    );
    final noUrls = starter(
      MockClient((_) async => http.Response('', 200)),
      urls: (_) => const [],
    );
    await expectLater(
      noUrls.install(info),
      throwsA(isA<StarterPhrasebookDownloadException>()),
    );
  });

  test('delete and deleteAll remove the packs', () async {
    final es = starterPackBytes(starterPackJson(id: 'es', name: 'Spanish'));
    await installStarterPack(store, bytes);
    await installStarterPack(store, es, id: 'es', name: 'Spanish');
    final packs = starter(MockClient((_) async => http.Response('', 500)));
    expect((await packs.installed()).map((p) => p.id), ['pt', 'es']);
    await packs.load('pt');
    await packs.delete('pt');
    expect((await packs.installed()).map((p) => p.id), ['es']);
    expect(await packs.load('pt'), isNull);
    expect(store.values.keys, {
      StarterPhrasebooks.indexKey,
      '${StarterPhrasebooks.packKeyPrefix}es',
    });
    await packs.deleteAll();
    expect(store.values, isEmpty);
    expect(await packs.installed(), isEmpty);
    await packs.close();
  });

  test('a damaged index or pack reads as nothing', () async {
    store.values[StarterPhrasebooks.indexKey] = jsonEncode([
      {'id': 'pt'},
      'x',
    ]);
    expect(
      await starter(MockClient((_) async => http.Response('', 500)))
          .installed(),
      isEmpty,
    );
    store.values[StarterPhrasebooks.indexKey] = '{nope';
    expect(
      await starter(MockClient((_) async => http.Response('', 500)))
          .installed(),
      isEmpty,
    );

    final fresh = MemoryStore();
    await installStarterPack(fresh, bytes);
    fresh.values.remove('${StarterPhrasebooks.packKeyPrefix}pt');
    final packs = StarterPhrasebooks(
      catalog: StarterPhrasebookCatalog(const []),
      store: fresh,
    );
    expect(await packs.load('pt'), isNull);
    fresh.values['${StarterPhrasebooks.packKeyPrefix}pt'] = '!!';
    expect(await packs.load('pt'), isNull);
  });

  group('starterPhrasebookUrls', () {
    test('the catalogue URL without a mirror', () {
      expect(starterPhrasebookUrls(info, source: ModelSource.defaultHosts), [
        info.url,
      ]);
    });

    test('the mirror first, then the catalogue when it falls back', () {
      const custom = ModelSource(
        kind: ModelSourceKind.custom,
        customUrl: 'https://models.example/mirror/',
      );
      expect(starterPhrasebookUrls(info, source: custom), [
        Uri.parse('https://models.example/mirror/phrasebooks/pt.json.gz'),
      ]);
      const fallback = ModelSource(
        kind: ModelSourceKind.custom,
        customUrl: 'https://models.example/mirror/',
        fallbackToDefault: true,
      );
      expect(starterPhrasebookUrls(info, source: fallback), [
        Uri.parse('https://models.example/mirror/phrasebooks/pt.json.gz'),
        info.url,
      ]);
    });
  });

  group('bundledStarterCatalog', () {
    test('is empty until the first release', () {
      expect(bundledStarterCatalog().isEmpty, isTrue);
    });

    test('reads a catalogue, and an invalid one as empty', () {
      final catalog = bundledStarterCatalog(
        jsonEncode({
          'schemaVersion': 1,
          'release': 'phrasebooks-2026-10-22',
          'packs': [info.toJson()],
        }),
      );
      expect(catalog.packs.single, info);
      expect(catalog.release, 'phrasebooks-2026-10-22');
      expect(bundledStarterCatalog('{"schemaVersion": 2}').isEmpty, isTrue);
    });
  });

  test('createStarterPhrasebooks uses the bundled catalogue', () {
    final packs = createStarterPhrasebooks(store);
    expect(packs.catalog.isEmpty, isTrue);
    expect(packs.store, store);
  });
}
