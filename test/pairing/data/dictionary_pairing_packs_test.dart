import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/pairing/data/dictionary_pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';

void main() {
  late Directory temp;
  late Uint8List spanish;
  late DictionaryPackInfo es;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_dict_');
    spanish = spanishPack();
    es = packInfo('es', spanish);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  DictionaryPacks packs(
    MemoryDictionaryPackStorage storage, {
    List<DictionaryPackInfo>? catalog,
  }) => DictionaryPacks(
    catalog: DictionaryPackCatalog(catalog ?? [es]),
    storage: storage,
    httpClient: MockClient((request) async => http.Response('no', 500)),
  );

  Future<List<File>> copy(PairingItem item, List<int> bytes) async => [
    File('${temp.path}/in/${item.files.single.name}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes),
  ];

  group('DictionaryPairingPacks', () {
    test('offers the installed packs', () async {
      final storage = MemoryDictionaryPackStorage()
        ..put(storedPack(es), spanish);
      final sender = DictionaryPairingPacks(packs(storage));
      expect(sender.kind, PairingItemKind.dictionary);
      final outgoing = await sender.outgoing();
      final file = outgoing.single.item.files.single;
      expect(outgoing.single.item.key, 'es');
      expect(file.name, 'es.mzd');
      expect(file.size, spanish.length);
      expect(file.sha256, es.sha256);
      expect(
        await outgoing.single.readers['es.mzd']!().expand((c) => c).toList(),
        spanish,
      );
    });

    test('a phone without the pack takes and installs it', () async {
      final sender = DictionaryPairingPacks(
        packs(MemoryDictionaryPackStorage()..put(storedPack(es), spanish)),
      );
      final item = (await sender.outgoing()).single.item;
      final receiverPacks = packs(MemoryDictionaryPackStorage());
      final receiver = DictionaryPairingPacks(receiverPacks);
      expect((await receiver.plan(item)).status, PairingItemStatus.available);
      expect(
        await receiver.install(item, await copy(item, spanish)),
        PairingItemOutcome.installed,
      );
      expect(await receiverPacks.installedPack('es'), storedPack(es));
      expect(
        await receiver.plan(item),
        const PairingPlan.installed(language: 'es'),
      );
    });

    test('a damaged file installs nothing', () async {
      final receiverPacks = packs(MemoryDictionaryPackStorage());
      final receiver = DictionaryPairingPacks(receiverPacks);
      final item = PairingItem(
        kind: PairingItemKind.dictionary,
        key: 'es',
        files: [PairingFile(name: 'es.mzd', size: spanish.length)],
      );
      final damaged = Uint8List.fromList(spanish)..[5] ^= 1;
      expect(
        await receiver.install(item, await copy(item, damaged)),
        PairingItemOutcome.damaged,
      );
      expect(await receiverPacks.installed(), isEmpty);
    });

    test('takes nothing it does not know or cannot store', () async {
      const item = PairingItem(
        kind: PairingItemKind.dictionary,
        key: 'de',
        files: [PairingFile(name: 'de.mzd', size: 3)],
      );
      final receiver = DictionaryPairingPacks(
        packs(MemoryDictionaryPackStorage()),
      );
      expect(await receiver.plan(item), const PairingPlan.incompatible());
      expect(
        await receiver.install(item, const []),
        PairingItemOutcome.incompatible,
      );
      final spanishItem = PairingItem(
        kind: PairingItemKind.dictionary,
        key: 'es',
        files: [PairingFile(name: 'es.mzd', size: spanish.length - 1)],
      );
      expect(
        await receiver.plan(spanishItem),
        const PairingPlan.incompatible(),
      );
      final unsupported = DictionaryPairingPacks(
        packs(MemoryDictionaryPackStorage(isSupported: false)),
      );
      expect(
        await unsupported.plan(spanishItem),
        const PairingPlan.incompatible(),
      );
      expect(
        await unsupported.install(
          spanishItem,
          await copy(spanishItem, spanish),
        ),
        PairingItemOutcome.incompatible,
      );
    });
  });
}
