import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:translation_repository/translation_repository.dart';

import 'dictionary_pack_fixtures.dart';

void main() {
  late Uint8List spanish;
  late Uint8List english;
  late DictionaryPackInfo es;
  late DictionaryPackInfo en;
  late MemoryDictionaryPackStorage storage;
  late List<Uri> requested;

  setUp(() {
    spanish = spanishPack();
    english = englishPack();
    es = packInfo('es', spanish);
    en = packInfo('en', english, name: 'English');
    storage = MemoryDictionaryPackStorage();
    requested = [];
  });

  DictionaryPacks packs({
    http.Client? client,
    Future<bool> Function()? isMetered,
    List<Uri> Function(DictionaryPackInfo pack)? downloadUrls,
    DictionaryPackStorage? store,
    FreeSpace? freeSpace,
  }) => DictionaryPacks(
    catalog: DictionaryPackCatalog([es, en]),
    storage: store ?? storage,
    httpClient:
        client ??
        MockClient((request) async {
          requested.add(request.url);
          final name = request.url.pathSegments.last;
          return switch (name) {
            'es.mzd' => http.Response.bytes(spanish, 200),
            'en.mzd' => http.Response.bytes(english, 200),
            _ => http.Response('missing', 404),
          };
        }),
    isMeteredConnection: isMetered,
    downloadUrls: downloadUrls,
    freeSpace: freeSpace,
  );

  group('free space', () {
    FreeSpace answering(int bytes) =>
        FreeSpace(isWeb: true, browser: () async => bytes);

    test('a pack that does not fit is not downloaded', () async {
      await expectLater(
        packs(freeSpace: answering(100)).install(es),
        throwsA(isA<NotEnoughSpaceException>()),
      );
      expect(requested, isEmpty);
      await expectLater(
        packs(freeSpace: answering(100)).installFrom(es, Stream.value(spanish)),
        throwsA(isA<NotEnoughSpaceException>()),
      );
      expect(await packs().installed(), isEmpty);
    });

    test('a pack that fits is', () async {
      await packs(freeSpace: answering(requiredFreeSpace(es.size))).install(es);
      expect(requested, [es.url]);
    });
  });

  group('install', () {
    test('downloads, checks and installs a pack', () async {
      final dictionaries = packs();
      final changes = <void>[];
      final subscription = dictionaries.changes.listen(changes.add);
      final progress = <double>[];
      await dictionaries.install(es, onProgress: progress.add);
      expect(requested, [es.url]);
      expect(progress.first, 0);
      expect(progress.last, 1);
      expect(await dictionaries.installed(), [storedPack(es)]);
      expect(await dictionaries.installedPack('es'), storedPack(es));
      expect(await dictionaries.installedPack('en'), isNull);
      expect(await dictionaries.installedLanguages(), ['es']);
      await pumpEventQueue();
      expect(changes, hasLength(1));
      // Installed already: no new download.
      await dictionaries.install(es);
      expect(requested, hasLength(1));
      await subscription.cancel();
    });

    test('shares a running download', () async {
      final dictionaries = packs();
      await Future.wait([dictionaries.install(es), dictionaries.install(es)]);
      expect(requested, hasLength(1));
    });

    test('rejects a file with the wrong checksum', () async {
      final damaged = Uint8List.fromList(spanish)..[100] ^= 1;
      final dictionaries = packs(
        client: MockClient((_) async => http.Response.bytes(damaged, 200)),
      );
      await expectLater(
        dictionaries.install(es),
        throwsA(isA<DictionaryPackChecksumException>()),
      );
      expect(await dictionaries.installed(), isEmpty);
    });

    test('rejects a file that is too long or too short', () async {
      for (final bytes in [
        Uint8List.fromList([...spanish, 0]),
        Uint8List.sublistView(spanish, 1),
      ]) {
        final dictionaries = packs(
          client: MockClient((_) async => http.Response.bytes(bytes, 200)),
        );
        await expectLater(
          dictionaries.install(es),
          throwsA(isA<DictionaryPackChecksumException>()),
        );
      }
      expect(await storage.list(), isEmpty);
    });

    test('reports server and connection errors', () async {
      final notFound = packs(
        client: MockClient((_) async => http.Response('gone', 404)),
      );
      await expectLater(
        notFound.install(es),
        throwsA(
          isA<DictionaryPackDownloadException>()
              .having((error) => error.statusCode, 'statusCode', 404)
              .having((error) => error.url, 'url', es.url),
        ),
      );
      final offline = packs(
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        offline.install(es),
        throwsA(
          isA<DictionaryPackDownloadException>().having(
            (error) => error.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
      Stream<List<int>> interrupted() async* {
        yield spanish.sublist(0, 10);
        throw const SocketExceptionLike();
      }

      final broken = packs(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(interrupted(), 200),
        ),
      );
      await expectLater(
        broken.install(es),
        throwsA(isA<DictionaryPackDownloadException>()),
      );
      expect(await storage.list(), isEmpty);
    });

    test('tries the next URL when a server fails', () async {
      final mirror = Uri.parse('https://mirror.example/dictionary/es.mzd');
      final dictionaries = packs(
        client: MockClient((request) async {
          requested.add(request.url);
          return request.url == mirror
              ? http.Response('nope', 503)
              : http.Response.bytes(spanish, 200);
        }),
        downloadUrls: (pack) => [mirror, pack.url],
      );
      await dictionaries.install(es);
      expect(requested, [mirror, es.url]);
      expect(await dictionaries.installedLanguages(), ['es']);
    });

    test('stops on a metered network when Wi-Fi only', () async {
      final dictionaries = packs(isMetered: () async => true);
      await expectLater(
        dictionaries.install(es, wifiOnly: true),
        throwsA(isA<DictionaryPackMeteredException>()),
      );
      expect(requested, isEmpty);
      await dictionaries.install(es);
      expect(requested, hasLength(1));
    });

    test('needs storage', () async {
      final dictionaries = packs(
        store: MemoryDictionaryPackStorage(isSupported: false),
      );
      expect(dictionaries.isSupported, isFalse);
      expect(await dictionaries.installed(), isEmpty);
      await expectLater(
        dictionaries.install(es),
        throwsA(isA<DictionaryPackUnsupportedException>()),
      );
    });

    test('replaces another version and reopens it', () async {
      final old = packInfo('es', englishPack());
      storage.put(storedPack(old), englishPack());
      final dictionaries = packs();
      expect((await dictionaries.lookUp('cat'))?.entry.word, 'cat');
      await dictionaries.install(es);
      expect(await dictionaries.installed(), [storedPack(es)]);
      expect(await dictionaries.lookUp('cat'), isNull);
      expect((await dictionaries.lookUp('gato'))?.entry.word, 'gato');
    });
  });

  test('delete removes a pack', () async {
    storage.put(storedPack(es), spanish);
    final dictionaries = packs();
    expect(await dictionaries.lookUp('gato', language: 'es'), isNotNull);
    final changed = dictionaries.changes.first;
    await dictionaries.delete('es');
    await changed;
    expect(await dictionaries.installed(), isEmpty);
    expect(await dictionaries.lookUp('gato'), isNull);
  });

  group('lookUp', () {
    setUp(() {
      storage
        ..put(storedPack(es), spanish)
        ..put(storedPack(en), english);
    });

    test('answers from the pack of the language', () async {
      final dictionaries = packs();
      final answer = (await dictionaries.lookUp(
        'Gatos',
        language: 'es-MX',
        target: 'en',
      ))!;
      expect(answer.language, 'es');
      expect(answer.entry.word, 'gato');
      expect(answer.inflectedForm, 'Gatos');
      expect(answer.entry.examples.single.translation, 'The cat sleeps.');
      expect(answer.attribution.text, 'Spanish entries from Wiktionary.');
      expect(await dictionaries.lookUp('cat', language: 'es'), isNull);
      expect(await dictionaries.lookUp('gato', language: 'fr'), isNull);
      expect(await dictionaries.lookUp('  '), isNull);
    });

    test('picks the closest match when the language is detected', () async {
      final dictionaries = packs();
      // `gato` in Spanish beats `Gato` in English; `Gato` the other way.
      expect((await dictionaries.lookUp('gato'))!.language, 'es');
      expect((await dictionaries.lookUp('Gato'))!.language, 'en');
      // A tie: the first pack (by id) answers.
      expect((await dictionaries.lookUp('GATO'))!.language, 'en');
      final cat = (await dictionaries.lookUp('cat', target: 'de'))!;
      expect(cat.language, 'en');
      expect(cat.entry.senses.single.translations, ['Katze']);
      expect((await dictionaries.lookUp('arbol'))!.entry.word, 'árbol');
      expect((await dictionaries.lookUp('went'))!.inflectedForm, 'went');
      expect(await dictionaries.lookUp('zebra'), isNull);
    });

    test('suggests words from the installed packs', () async {
      final dictionaries = packs();
      expect(await dictionaries.suggest('ga'), [
        'Gato',
        'gata',
        'gato',
        'gatos',
      ]);
      expect(await dictionaries.suggest('g', limit: 2), ['Gato', 'go']);
      expect(await dictionaries.suggest('ga', language: 'es'), [
        'gata',
        'gato',
        'gatos',
      ]);
      expect(await dictionaries.suggest('g', language: 'en'), ['Gato', 'go']);
      expect(await dictionaries.suggest(''), isEmpty);
      expect(await dictionaries.suggest('g', limit: 0), isEmpty);
    });

    test('skips damaged and unreadable packs', () async {
      final damaged = Uint8List.fromList(spanish)
        ..fillRange(spanish.length - 40, spanish.length, 0);
      storage.put(storedPack(es), damaged);
      final dictionaries = packs();
      expect(await dictionaries.lookUp('gato', language: 'es'), isNull);
      expect(await dictionaries.suggest('ga', language: 'es'), isEmpty);
      // The English pack still answers.
      expect((await dictionaries.lookUp('Gato'))!.language, 'en');
      final failing = packs(store: _FailingStorage());
      expect(await failing.lookUp('gato'), isNull);
      expect(await failing.suggest('ga'), isEmpty);
    });

    test('skips a pack whose blocks are damaged', () async {
      final bytes = Uint8List.fromList(spanish);
      // The first entry block's gzip header.
      bytes[_dataStart(spanish)] = 0;
      storage.put(storedPack(es), bytes);
      final dictionaries = packs();
      expect(await dictionaries.lookUp('gato', language: 'es'), isNull);
      expect(await dictionaries.suggest('ga', language: 'es'), isNotEmpty);
    });
  });

  test('close closes the open packs and its client', () async {
    storage.put(storedPack(es), spanish);
    final dictionaries = DictionaryPacks(
      catalog: DictionaryPackCatalog(const []),
      storage: storage,
    );
    expect(await dictionaries.lookUp('gato'), isNotNull);
    await dictionaries.close();
  });

  test('exceptions describe themselves', () {
    expect(
      '${const DictionaryPackChecksumException('es', 'bad')}',
      'DictionaryPackChecksumException(es: bad)',
    );
    expect(
      '${const DictionaryPackDownloadException('es', 'HTTP 404')}',
      'DictionaryPackDownloadException(es: HTTP 404)',
    );
    expect(
      '${const DictionaryPackMeteredException('es')}',
      'DictionaryPackMeteredException(es: Metered network)',
    );
    expect(
      '${const DictionaryPackUnsupportedException('es')}',
      contains('DictionaryPackUnsupportedException(es'),
    );
  });
}

/// Where the data section of [pack] starts.
int _dataStart(Uint8List pack) =>
    DictionaryPackHeader.prefixLength +
    DictionaryPackHeader.metadataLength(pack);

class SocketExceptionLike implements Exception {
  const new();
}

/// Lists a pack it cannot open.
class _FailingStorage extends MemoryDictionaryPackStorage {
  @override
  Future<List<StoredDictionaryPack>> list() async => [
    const StoredDictionaryPack(
      id: 'es',
      language: 'es',
      size: 1,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ),
  ];
}
