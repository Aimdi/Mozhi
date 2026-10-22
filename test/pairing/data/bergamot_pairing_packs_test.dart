import 'dart:io';

import 'package:bergamot_translator/bergamot_translator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/data/bergamot_pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';

import '../helpers/bergamot_fixture.dart';
import '../helpers/loopback.dart';

void main() {
  late Directory temp;
  late TinyCatalog catalog;
  late BergamotTranslator sender;
  late BergamotTranslator receiver;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_bergamot_');
    catalog = TinyCatalog()
      ..add('de', 'en', 'v1')
      ..add('en', 'de', 'v1')
      ..add('fr', 'en', 'v1')
      ..add('en', 'fr', 'v1');
    sender = catalog.translator(Directory('${temp.path}/sender'));
    receiver = catalog.translator(Directory('${temp.path}/receiver'));
    await sender.downloadLanguage('de', wifiOnly: false);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  /// The files of [outgoing], written to a folder as a transfer would.
  Future<List<File>> copy(PairingOutgoingItem outgoing) async {
    final files = <File>[];
    for (final file in outgoing.item.files) {
      final copy = File('${temp.path}/in/${file.name}')
        ..createSync(recursive: true);
      final sink = copy.openWrite();
      await sink.addStream(outgoing.readers[file.name]!());
      await sink.close();
      files.add(copy);
    }
    return files;
  }

  group('BergamotPairingPacks', () {
    test('offers each downloaded language with its files', () async {
      final packs = BergamotPairingPacks(sender);
      expect(packs.kind, PairingItemKind.translation);
      final outgoing = await packs.outgoing();
      expect([for (final o in outgoing) o.item.key], ['de']);
      final item = outgoing.single.item;
      expect(item.files, hasLength(6));
      expect(
        item.files.map((file) => file.name),
        containsAll(['de-en/model.de-en.bin', 'en-de/vocab.en-de.bin']),
      );
      expect(item.files.every((file) => file.sha256 != null), isTrue);
    });

    test('offers nothing where the engine does not run', () async {
      final packs = BergamotPairingPacks(
        catalog.translator(Directory('${temp.path}/sender'), available: false),
      );
      expect(await packs.outgoing(), isEmpty);
    });

    test('a phone without the language takes and installs it', () async {
      final outgoing = (await BergamotPairingPacks(sender).outgoing()).single;
      final packs = BergamotPairingPacks(receiver);
      final plan = await packs.plan(outgoing.item);
      expect(plan.status, PairingItemStatus.available);
      expect(plan.files, hasLength(6));
      expect(
        await packs.install(outgoing.item, await copy(outgoing)),
        PairingItemOutcome.installed,
      );
      expect(await receiver.downloadedLanguages(), contains('de'));
      expect(
        await packs.plan(outgoing.item),
        const PairingPlan.installed(language: 'de'),
      );
    });

    test('a phone with one direction asks for the other only', () async {
      await receiver.models.install(catalog.build().model('de', 'en')!);
      final outgoing = (await BergamotPairingPacks(sender).outgoing()).single;
      final plan = await BergamotPairingPacks(receiver).plan(outgoing.item);
      expect(
        plan.files.map((file) => file.name),
        everyElement(startsWith('en-de/')),
      );
    });

    test('files of another version are not taken', () async {
      final outgoing = (await BergamotPairingPacks(sender).outgoing()).single;
      final newer = TinyCatalog()
        ..add('de', 'en', 'v2')
        ..add('en', 'de', 'v1');
      final packs = BergamotPairingPacks(
        newer.translator(Directory('${temp.path}/newer')),
      );
      expect(await packs.plan(outgoing.item), const PairingPlan.incompatible());
    });

    test(
      'unknown languages and engines that do not run take nothing',
      () async {
        const item = PairingItem(
          kind: PairingItemKind.translation,
          key: 'xx',
          files: [],
        );
        expect(
          await BergamotPairingPacks(receiver).plan(item),
          const PairingPlan.incompatible(),
        );
        final outgoing = (await BergamotPairingPacks(sender).outgoing()).single;
        final off = catalog.translator(
          Directory('${temp.path}/off'),
          available: false,
        );
        expect(
          await BergamotPairingPacks(off).plan(outgoing.item),
          const PairingPlan.incompatible(),
        );
      },
    );

    test('a damaged file installs nothing', () async {
      final outgoing = (await BergamotPairingPacks(sender).outgoing()).single;
      final files = await copy(outgoing);
      final bytes = files.first.readAsBytesSync()..[3] ^= 1;
      files.first.writeAsBytesSync(bytes);
      expect(
        await BergamotPairingPacks(receiver).install(outgoing.item, files),
        PairingItemOutcome.damaged,
      );
      expect(
        await BergamotPairingPacks(receiver)
            .install(outgoing.item, files.sublist(1)),
        PairingItemOutcome.damaged,
      );
      expect(await receiver.downloadedLanguages(), isNot(contains('de')));
    });

    test('files of one direction only leave the language missing', () async {
      final outgoing = (await BergamotPairingPacks(sender).outgoing()).single;
      final files = [
        for (final file in await copy(outgoing))
          if (file.path.contains('en-de')) file,
      ];
      expect(
        await BergamotPairingPacks(receiver).install(outgoing.item, files),
        PairingItemOutcome.damaged,
      );
    });

    test('goes from phone to phone over a connection', () async {
      final (a, b) = await channelPair();
      addTearDown(() {
        a.destroy();
        b.destroy();
      });
      final sending = PairingSender(a);
      final receiving = PairingReceiver(
        b,
        PairingLibrary(packs: [BergamotPairingPacks(receiver)]),
        workDirectory: Directory('${temp.path}/work'),
      );
      final requested = sending.offer(
        await PairingLibrary(packs: [BergamotPairingPacks(sender)])
            .outgoingPacks(),
      );
      final offered = await receiving.offer();
      final received = receiving.accept({
        for (final o in offered) o.item.id,
      }, mode: BackupRestoreMode.merge);
      final results = await sending.send(await requested);
      expect(results, const [
        PairingItemResult('translation:de', PairingItemOutcome.installed),
      ]);
      expect(await received, results);
      expect(await receiver.downloadedLanguages(), contains('de'));
    });
  });
}
