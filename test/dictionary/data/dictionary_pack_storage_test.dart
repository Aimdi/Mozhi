import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/dictionary/data/dictionary_pack_storage.dart';
import 'package:mozhi/dictionary/data/dictionary_pack_storage_io.dart';
import 'package:translation_repository/translation_repository.dart';

import 'dictionary_pack_fixtures.dart';

void main() {
  late Directory temp;
  late Directory root;
  late FileDictionaryPackStorage storage;
  late Uint8List bytes;
  late StoredDictionaryPack pack;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('dictionary_packs_test');
    root = Directory('${temp.path}/dictionary');
    storage = FileDictionaryPackStorage(root: () async => root);
    bytes = spanishPack();
    pack = storedPack(packInfo('es', bytes));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> install(StoredDictionaryPack record, Uint8List data) async {
    final sink = await storage.create(record.id);
    await sink.add(Uint8List.sublistView(data, 0, 100));
    await sink.add(Uint8List.sublistView(data, 100));
    await sink.commit(record);
  }

  group('FileDictionaryPackStorage', () {
    test('installs, lists, opens and deletes packs', () async {
      expect(storage.isSupported, isTrue);
      expect(await storage.list(), isEmpty);
      await install(pack, bytes);
      expect(await storage.list(), [pack]);
      expect(File('${root.path}/es.mzd').readAsBytesSync(), bytes);
      final source = await storage.open('es');
      expect(source.length, bytes.length);
      // Concurrent reads run one after the other.
      final reads = await Future.wait([
        source.read(0, 8),
        source.read(8, 4),
        source.read(bytes.length - 2, 10),
      ]);
      expect(ascii.decode(reads[0]), 'MOZHIDCT');
      expect(reads[1], bytes.sublist(8, 12));
      expect(reads[2], bytes.sublist(bytes.length - 2));
      final reader = await DictionaryPackReader.open(source);
      expect((await reader.lookUp('gato')).single.entry.word, 'gato');
      await reader.close();
      await source.close();
      expect(() => source.read(0, 1), throwsStateError);
      await storage.delete('es');
      expect(await storage.list(), isEmpty);
      expect(File('${root.path}/es.mzd').existsSync(), isFalse);
      await storage.delete('es');
    });

    test('replaces another version', () async {
      final english = englishPack();
      await install(storedPack(packInfo('es', english)), english);
      await install(pack, bytes);
      expect(await storage.list(), [pack]);
      expect(File('${root.path}/es.mzd').readAsBytesSync(), bytes);
    });

    test('abort keeps the installed version', () async {
      await install(pack, bytes);
      final sink = await storage.create('es');
      await sink.add(Uint8List(10));
      await sink.abort();
      expect(await storage.list(), [pack]);
      expect(Directory('${root.path}/.downloads').listSync(), isEmpty);
    });

    test('refuses a commit of another size', () async {
      final sink = await storage.create('es');
      await sink.add(Uint8List(10));
      await expectLater(sink.commit(pack), throwsA(isA<FileSystemException>()));
      expect(await storage.list(), isEmpty);
    });

    test('ignores invalid records and files of the wrong size', () async {
      await install(pack, bytes);
      root.createSync(recursive: true);
      File('${root.path}/fr.json').writeAsStringSync('not json');
      File(
        '${root.path}/de.json',
      ).writeAsStringSync(jsonEncode({'schemaVersion': 2, ...pack.toJson()}));
      File(
        '${root.path}/it.json',
      ).writeAsStringSync(jsonEncode({'schemaVersion': 1, ...pack.toJson()}));
      File('${root.path}/pt.json')
          .writeAsStringSync(jsonEncode({'schemaVersion': 1, 'id': 'pt'}));
      expect(await storage.list(), [pack]);
      File('${root.path}/es.mzd').writeAsBytesSync([1, 2, 3]);
      expect(await storage.list(), isEmpty);
    });

    test('cleans up leftovers', () async {
      await storage.cleanUp();
      await install(pack, bytes);
      final sink = await storage.create('fr');
      await sink.add(Uint8List(4));
      File('${root.path}/de.mzd').writeAsBytesSync([1]);
      await storage.cleanUp();
      expect(File('${root.path}/de.mzd').existsSync(), isFalse);
      expect(Directory('${root.path}/.downloads').listSync(), isEmpty);
      expect(await storage.list(), [pack]);
    });

    group('downloads kept for resuming', () {
      final url = Uri.parse('https://packs.example/es.mzd');
      late DictionaryPartialDownload download;

      setUp(
        () => download = DictionaryPartialDownload(
          url: url,
          size: bytes.length,
          sha256: pack.sha256,
        ),
      );

      Future<List<int>> kept(String id) async => [
        for (final chunk in await storage.readPartial(id).toList()) ...chunk,
      ];

      test('keeps what was written, across clean-ups', () async {
        expect(await storage.partial('es'), isNull);
        final sink = await storage.createPartial('es', download, append: false);
        await sink.add(Uint8List.sublistView(bytes, 0, 100));
        await sink.keep();
        await storage.cleanUp();

        final partial = (await storage.partial('es'))!;
        expect(partial.url, url);
        expect(partial.size, bytes.length);
        expect(partial.sha256, pack.sha256);
        expect(partial.received, 100);
        expect(partial.continues(pack.sha256, bytes.length, url), isTrue);
        expect(
          partial.continues(pack.sha256, bytes.length, Uri.parse('https://x')),
          isFalse,
        );
        expect(await kept('es'), bytes.sublist(0, 100));
      });

      test('appends the rest and installs the whole', () async {
        final first = await storage.createPartial(
          'es',
          download,
          append: false,
        );
        await first.add(Uint8List.sublistView(bytes, 0, 100));
        await first.keep();

        final rest = await storage.createPartial('es', download, append: true);
        await rest.add(Uint8List.sublistView(bytes, 100));
        await rest.commit(pack);

        expect(await storage.list(), [pack]);
        expect(File('${root.path}/es.mzd').readAsBytesSync(), bytes);
        expect(await storage.partial('es'), isNull);
        expect(Directory('${root.path}/.downloads').listSync(), isEmpty);
      });

      test('starts afresh without append, and abort drops it', () async {
        final first = await storage.createPartial(
          'es',
          download,
          append: false,
        );
        await first.add(Uint8List(50));
        await first.keep();

        final again = await storage.createPartial(
          'es',
          download,
          append: false,
        );
        await again.add(Uint8List(10));
        await again.keep();
        expect((await storage.partial('es'))!.received, 10);

        final dropped = await storage.createPartial(
          'es',
          download,
          append: true,
        );
        await dropped.abort();
        expect(await storage.partial('es'), isNull);
      });

      test('drops records that are invalid or complete', () async {
        final downloads = Directory('${root.path}/.downloads')
          ..createSync(recursive: true);
        File('${downloads.path}/es.part').writeAsBytesSync([1, 2]);
        File('${downloads.path}/es.part.json').writeAsStringSync('nonsense');
        expect(await storage.partial('es'), isNull);
        expect(File('${downloads.path}/es.part').existsSync(), isFalse);

        File('${downloads.path}/fr.part').writeAsBytesSync(bytes);
        File('${downloads.path}/fr.part.json')
            .writeAsStringSync(jsonEncode(download.toJson()));
        expect(await storage.partial('fr'), isNull);

        // A part without its record is a leftover.
        File('${downloads.path}/it.part').writeAsBytesSync([1]);
        File('${downloads.path}/pt.part.json').writeAsStringSync('{}');
        await storage.cleanUp();
        expect(downloads.listSync(), isEmpty);
      });

      test('a plain sink cannot be kept', () async {
        final sink = await storage.create('es');
        await sink.add(Uint8List(4));
        await (sink as ResumableDictionaryPackSink).keep();
        expect(await storage.partial('es'), isNull);
        expect(Directory('${root.path}/.downloads').listSync(), isEmpty);
      });

      test('reads JSON of a download tolerantly', () {
        expect(DictionaryPartialDownload.fromJson('x'), isNull);
        expect(
          DictionaryPartialDownload.fromJson({...download.toJson(), 'size': 0}),
          isNull,
        );
        expect(
          DictionaryPartialDownload.fromJson({
            ...download.toJson(),
            'url': 'a',
          }),
          isNull,
        );
        expect(
          DictionaryPartialDownload.fromJson({
            ...download.toJson(),
            'sha256': 'abc',
          }),
          isNull,
        );
        expect(DictionaryPartialDownload.fromJson(download.toJson())?.url, url);
      });
    });

    test('rejects ids that are not file names', () async {
      expect(() => storage.create('../x'), throwsArgumentError);
      expect(() => storage.open('ES'), throwsArgumentError);
      expect(() => storage.delete(''), throwsArgumentError);
      await expectLater(
        storage.open('es'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('MemoryDictionaryPackStorage', () {
    test('keeps packs in memory', () async {
      final memory = MemoryDictionaryPackStorage();
      final sink = await memory.create('es');
      await sink.add(bytes);
      await sink.commit(pack);
      expect(await memory.list(), [pack]);
      expect((await memory.open('es')).length, bytes.length);
      final aborted = await memory.create('fr');
      await aborted.add(bytes);
      await aborted.abort();
      await memory.cleanUp();
      await memory.delete('es');
      expect(await memory.list(), isEmpty);
      expect(() => memory.open('es'), throwsStateError);
      expect(() => memory.create('../x'), throwsArgumentError);
    });

    test('keeps downloads for resuming', () async {
      final memory = MemoryDictionaryPackStorage();
      final download = DictionaryPartialDownload(
        url: Uri.parse('https://packs.example/es.mzd'),
        size: bytes.length,
        sha256: pack.sha256,
      );
      expect(await memory.partial('es'), isNull);
      expect(await memory.readPartial('es').toList(), isEmpty);
      final first = await memory.createPartial('es', download, append: false);
      await first.add(Uint8List.sublistView(bytes, 0, 100));
      await first.keep();
      expect((await memory.partial('es'))!.received, 100);
      expect(await memory.readPartial('es').single, bytes.sublist(0, 100));

      final rest = await memory.createPartial('es', download, append: true);
      await rest.add(Uint8List.sublistView(bytes, 100));
      await rest.commit(pack);
      expect(await memory.partial('es'), isNull);
      expect((await memory.open('es')).length, bytes.length);

      final plain = await memory.create('fr');
      await (plain as ResumableDictionaryPackSink).keep();
      expect(await memory.partial('fr'), isNull);
    });
  });

  group('StoredDictionaryPack', () {
    test('round-trips through JSON', () {
      expect(StoredDictionaryPack.fromJson(pack.toJson()), pack);
      expect(
        StoredDictionaryPack.fromJson({...pack.toJson()}..remove('name')),
        isA<StoredDictionaryPack>().having((p) => p.name, 'name', ''),
      );
      expect(pack.hashCode, storedPack(packInfo('es', bytes)).hashCode);
      expect('$pack', 'StoredDictionaryPack(es)');
    });

    test('rejects invalid records', () {
      for (final json in <Object?>[
        'x',
        {...pack.toJson(), 'id': 'ES'},
        {...pack.toJson(), 'language': ''},
        {...pack.toJson(), 'size': 0},
        {...pack.toJson(), 'sha256': 'abc'},
      ]) {
        expect(StoredDictionaryPack.fromJson(json), isNull, reason: '$json');
      }
    });
  });

  test('createDictionaryPackStorage keeps packs in the support folder', () {
    expect(createDictionaryPackStorage(), isA<FileDictionaryPackStorage>());
    expect(dictionaryPacksFolder, 'dictionary');
  });
}
