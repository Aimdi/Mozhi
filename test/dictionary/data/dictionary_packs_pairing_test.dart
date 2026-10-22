import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:translation_repository/translation_repository.dart';

import 'dictionary_pack_fixtures.dart';

/// `DictionaryPacks.read` and `installFrom`: packs copied between phones
/// (lib/pairing).
void main() {
  late Uint8List spanish;
  late DictionaryPackInfo es;
  late MemoryDictionaryPackStorage storage;

  setUp(() {
    spanish = spanishPack();
    es = packInfo('es', spanish);
    storage = MemoryDictionaryPackStorage();
  });

  DictionaryPacks packs({DictionaryPackStorage? store}) => DictionaryPacks(
    catalog: DictionaryPackCatalog([es]),
    storage: store ?? storage,
    httpClient: MockClient((request) async => http.Response('no', 500)),
  );

  group('read', () {
    test('reads an installed pack in chunks', () async {
      storage.put(storedPack(es), spanish);
      final chunks = await packs().read('es', chunkSize: 100).toList();
      expect(chunks.first, hasLength(100));
      expect(chunks.every((chunk) => chunk.length <= 100), isTrue);
      expect([for (final chunk in chunks) ...chunk], spanish);
    });

    test('fails for a pack that is not installed', () async {
      await expectLater(packs().read('es').toList(), throwsStateError);
    });
  });

  group('installFrom', () {
    test('checks and installs the bytes, without the network', () async {
      final dictionaries = packs();
      final changes = <void>[];
      final subscription = dictionaries.changes.listen(changes.add);
      final progress = <double>[];
      await dictionaries.installFrom(
        es,
        Stream.fromIterable([spanish.sublist(0, 10), spanish.sublist(10)]),
        onProgress: progress.add,
      );
      expect(progress.first, 0);
      expect(progress.last, 1);
      expect(await dictionaries.installedPack('es'), storedPack(es));
      expect(
        (await dictionaries.lookUp('gato', language: 'es'))?.entry.word,
        'gato',
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(1));
      await subscription.cancel();
    });

    test('refuses bytes that do not match the catalogue', () async {
      final dictionaries = packs();
      final damaged = Uint8List.fromList(spanish)..[20] ^= 1;
      await expectLater(
        dictionaries.installFrom(es, Stream.value(damaged)),
        throwsA(isA<DictionaryPackChecksumException>()),
      );
      await expectLater(
        dictionaries.installFrom(es, Stream.value([...spanish, 1])),
        throwsA(isA<DictionaryPackChecksumException>()),
      );
      expect(await dictionaries.installed(), isEmpty);
    });

    test('passes on read errors and installs nothing', () async {
      final dictionaries = packs();
      await expectLater(
        dictionaries.installFrom(es, Stream.error(StateError('gone'))),
        throwsStateError,
      );
      expect(await dictionaries.installed(), isEmpty);
    });

    test('refuses where packs cannot be stored', () async {
      final dictionaries = packs(
        store: MemoryDictionaryPackStorage(isSupported: false),
      );
      await expectLater(
        dictionaries.installFrom(es, Stream.value(spanish)),
        throwsA(isA<DictionaryPackUnsupportedException>()),
      );
    });
  });
}
