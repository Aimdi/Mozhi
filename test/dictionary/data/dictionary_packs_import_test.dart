import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/data/picked_import_file.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:translation_repository/translation_repository.dart';

import 'dictionary_pack_fixtures.dart';

/// A picked file that counts its reads.
class _Counted {
  new(this.name, this.bytes, {this.knownLength = true});

  final String name;
  final Uint8List bytes;
  final bool knownLength;
  int reads = 0;

  PickedImportFile get counted => PickedImportFile(
    name: name,
    length: knownLength ? bytes.length : null,
    read: () {
      reads++;
      return Stream.value(bytes);
    },
  );
}

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

  DictionaryPacks packs({DictionaryPackStorage? store, FreeSpace? freeSpace}) =>
      DictionaryPacks(
        catalog: DictionaryPackCatalog([es, en]),
        storage: store ?? storage,
        // Importing never touches the network.
        httpClient: MockClient((request) async {
          requested.add(request.url);
          return http.Response('no network', 500);
        }),
        freeSpace: freeSpace,
      );

  tearDown(() => expect(requested, isEmpty));

  PickedImportFile picked(String name, Uint8List bytes) =>
      PickedImportFile.bytes(name, bytes, chunkSize: 64);

  test('installs packs by name, with the checks of a download', () async {
    final dictionaries = packs();
    final changes = <void>[];
    final subscription = dictionaries.changes.listen(changes.add);

    final report = await dictionaries.importFiles([
      picked('ES.MZD', spanish),
      picked('notes.txt', Uint8List.fromList([1, 2, 3])),
    ]);
    await pumpEventQueue();
    await subscription.cancel();

    expect(report.packs, [
      DictionaryImportedPack(
        pack: es,
        status: DictionaryImportStatus.installed,
      ),
    ]);
    expect(report.installedAny, isTrue);
    expect(report.unmatchedFiles, ['notes.txt']);
    expect(await dictionaries.installed(), [storedPack(es)]);
    expect(changes, isNotEmpty);
    // And it reads words.
    expect(await dictionaries.installedLanguages(), ['es']);
  });

  test('a renamed copy is found by its size and SHA-256', () async {
    final report = await packs().importFiles([
      picked('download (2).bin', english),
    ]);

    expect(report.packs.single.pack, en);
    expect(report.packs.single.status, DictionaryImportStatus.installed);
    expect(report.unmatchedFiles, isEmpty);
  });

  test('a renamed file of a pack size but other bytes matches none', () async {
    final report = await packs().importFiles([
      picked('copy.bin', Uint8List(spanish.length)),
    ]);

    expect(report.packs, isEmpty);
    expect(report.unmatchedFiles, ['copy.bin']);
    expect(await storage.list(), isEmpty);
  });

  test('a damaged file installs nothing', () async {
    final damaged = Uint8List.fromList(spanish)..[20] ^= 0xff;
    final report = await packs().importFiles([picked('es.mzd', damaged)]);

    final entry = report.packs.single;
    expect(entry.status, DictionaryImportStatus.damaged);
    expect(entry.error, isA<DictionaryPackChecksumException>());
    expect(report.installedAny, isFalse);
    expect(await storage.list(), isEmpty);
  });

  test('a file of the wrong size is damaged without being read', () async {
    final short = _Counted('es.mzd', spanish.sublist(1));
    final report = await packs().importFiles([short.counted]);

    expect(report.packs.single.status, DictionaryImportStatus.damaged);
    expect(short.reads, 0);
  });

  test('an installed pack is not read again', () async {
    final dictionaries = packs();
    await dictionaries.importFiles([picked('es.mzd', spanish)]);
    final again = _Counted('es.mzd', spanish);
    final renamed = _Counted('x.mzd', spanish.sublist(2));

    final report = await dictionaries.importFiles([
      again.counted,
      renamed.counted,
      // Named like it but another size: the pack is there all the same.
      picked('ES.mzd', spanish.sublist(3)),
    ]);

    expect(report.packs.single.status, DictionaryImportStatus.alreadyInstalled);
    expect(again.reads, 0);
    expect(report.unmatchedFiles, ['x.mzd']);
  });

  test('a good copy wins over a damaged one', () async {
    final damaged = Uint8List.fromList(spanish)..[20] ^= 0xff;
    final report = await packs().importFiles([
      picked('es.mzd', damaged),
      picked('es.mzd', spanish),
      // Not read again once installed.
      picked('es.mzd', damaged),
    ]);

    expect(report.packs.single.status, DictionaryImportStatus.installed);
    expect(await storage.list(), [storedPack(es)]);
  });

  test('a file of unknown size is checked by name', () async {
    final unknown = _Counted('en.mzd', english, knownLength: false);
    final report = await packs().importFiles([unknown.counted]);

    expect(report.packs.single.status, DictionaryImportStatus.installed);
    expect(unknown.reads, 1);
  });

  test('no room or no storage fails the pack', () async {
    final full = await packs(
      freeSpace: FreeSpace(isWeb: true, browser: () async => 10),
    ).importFiles([picked('es.mzd', spanish), picked('renamed', english)]);
    expect(
      [for (final entry in full.packs) entry.status],
      [DictionaryImportStatus.failed, DictionaryImportStatus.failed],
    );
    expect(full.packs.first.error, isA<NotEnoughSpaceException>());

    final none = await packs(
      store: MemoryDictionaryPackStorage(isSupported: false),
    ).importFiles([picked('es.mzd', spanish)]);
    expect(none.packs.single.status, DictionaryImportStatus.failed);
    expect(none.packs.single.error, isA<DictionaryPackUnsupportedException>());
  });

  test('reports compare by pack, status and error', () {
    final a = DictionaryImportedPack(
      pack: es,
      status: DictionaryImportStatus.installed,
    );
    expect(
      a,
      DictionaryImportedPack(
        pack: es,
        status: DictionaryImportStatus.installed,
      ),
    );
    expect(
      a,
      isNot(
        DictionaryImportedPack(
          pack: es,
          status: DictionaryImportStatus.damaged,
        ),
      ),
    );
    expect(a.hashCode, isNot(0));
    expect('$a', 'DictionaryImportedPack(es, installed)');
    expect(const DictionaryImportReport().installedAny, isFalse);
  });

  test('PickedImportFile reads its bytes in chunks', () async {
    final file = PickedImportFile.bytes('a', spanish, chunkSize: 100);
    final chunks = await file.openRead().toList();
    expect(chunks.first, hasLength(100));
    expect([for (final chunk in chunks) ...chunk], spanish);
    expect(file.length, spanish.length);
    expect('$file', 'PickedImportFile(a, ${spanish.length})');
  });
}
