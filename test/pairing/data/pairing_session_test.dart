import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

import '../helpers/fake_packs.dart';
import '../helpers/loopback.dart';

/// [future], with its error (if any) handled, so that it may fail before
/// the test awaits it.
Future<T> watched<T>(Future<T> future) {
  unawaited(future.then((_) {}, onError: (Object _) {}));
  return future;
}

void main() {
  late Directory temp;
  late PairingChannel senderChannel;
  late PairingChannel receiverChannel;
  late FakePacks senderPacks;
  late FakePacks receiverPacks;
  late BackupRegistry senderBackup;
  late BackupRegistry receiverBackup;
  late FakeSection receiverHistory;

  final german = {
    'de-en/model.bin': bytesOf(150000, 3),
    'de-en/vocab.spm': bytesOf(1000, 5),
  };
  final french = {'fr-en/model.bin': bytesOf(500, 7)};

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_session_');
    (senderChannel, receiverChannel) = await channelPair();
    senderPacks = FakePacks(
      contents: {'de': german, 'fr': french, 'es': french},
    );
    receiverPacks = FakePacks(
      plans: {
        'fr': const PairingPlan.installed(),
        'es': const PairingPlan.incompatible(),
      },
    );
    senderBackup =
        BackupRegistry(
            appVersion: () async => '1.0.0',
            clock: () => DateTime.utc(2026, 10, 22),
          )
          ..register(FakeSection('history', ['hola']))
          ..register(FakeSection('settings', {'theme': 'dark'}));
    receiverHistory = FakeSection('history', ['mine']);
    receiverBackup = BackupRegistry(appVersion: () async => '1.0.0')
      ..register(receiverHistory)
      ..register(FakeSection('settings', null));
  });

  tearDown(() {
    senderChannel.destroy();
    receiverChannel.destroy();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  PairingSender sender({PairingTimeouts? timeouts}) => PairingSender(
    senderChannel,
    timeouts: timeouts ?? const PairingTimeouts(),
  );

  PairingReceiver receiver({PairingTimeouts? timeouts}) => PairingReceiver(
    receiverChannel,
    PairingLibrary(backup: receiverBackup, packs: [receiverPacks]),
    workDirectory: Directory('${temp.path}/work'),
    timeouts: timeouts ?? const PairingTimeouts(),
  );

  Future<List<PairingOutgoingItem>> offerAll() async => [
    await PairingBackupItem.outgoing(
      senderBackup,
      sections: {'history'},
      includeSecrets: false,
    ),
    ...await PairingLibrary(packs: [senderPacks]).outgoingPacks(),
  ];

  group('a transfer', () {
    test('sends what the receiver accepts and installs it', () async {
      final sending = sender();
      final receiving = receiver();
      expect(sending.sas, receiving.sas);

      final requested = sending.offer(await offerAll());
      final offered = await receiving.offer();
      expect(
        [for (final o in offered) o.item.id],
        ['data:backup', 'translation:de', 'translation:fr', 'translation:es'],
      );
      expect(offered.first.item.sections, ['history']);
      expect(offered.first.item.secrets, isFalse);
      expect(
        [for (final o in offered) o.plan.status],
        [
          PairingItemStatus.available,
          PairingItemStatus.available,
          PairingItemStatus.installed,
          PairingItemStatus.incompatible,
        ],
      );

      final receiverProgress = <PairingProgress>[];
      final received = receiving.accept(
        {'data:backup', 'translation:de', 'translation:fr', 'translation:es'},
        mode: BackupRestoreMode.merge,
        onProgress: receiverProgress.add,
      );
      final wanted = await requested;
      expect(
        [for (final w in wanted) w.item.id],
        ['data:backup', 'translation:de'],
      );
      final senderProgress = <PairingProgress>[];
      final sent = await sending.send(wanted, onProgress: senderProgress.add);
      const results = [
        PairingItemResult('data:backup', PairingItemOutcome.installed),
        PairingItemResult('translation:de', PairingItemOutcome.installed),
      ];
      expect(sent, results);
      expect(await received, results);

      expect(receiverHistory.restores.single.$1, {
        'value': ['hola'],
      });
      expect(receiverHistory.restores.single.$2, BackupRestoreMode.merge);
      expect(receiverPacks.installs['de'], {
        'model.bin': german['de-en/model.bin'],
        'vocab.spm': german['de-en/vocab.spm'],
      });
      expect(Directory('${temp.path}/work').existsSync(), isFalse);

      final total = senderProgress.last.totalBytes;
      expect(total, greaterThan(151000));
      expect(senderProgress.last.bytes, total);
      expect(senderProgress.last.installing, isTrue);
      expect(senderProgress.last.fraction, 1);
      expect(receiverProgress.last.bytes, total);
      expect(receiverProgress.where((p) => p.installing).map((p) => p.itemId), [
        'data:backup',
        'translation:de',
      ]);
    });

    test('carries secrets only when asked', () async {
      final item = await PairingBackupItem.outgoing(
        senderBackup,
        sections: {'history', 'settings'},
        includeSecrets: true,
      );
      expect(item.item.secrets, isTrue);
      expect(item.item.sections, ['history', 'settings']);
      final bytes = await item.readers['backup.json']!().first;
      expect(String.fromCharCodes(bytes), contains('"secret":"key"'));
    });

    test('accepting nothing ends the connection cleanly', () async {
      final sending = sender();
      final receiving = receiver();
      final requested = sending.offer(await offerAll());
      await receiving.offer();
      final received = receiving.accept(
        const {},
        mode: BackupRestoreMode.replace,
      );
      expect(await requested, isEmpty);
      expect(await sending.send(const []), isEmpty);
      expect(await received, isEmpty);
      await sending.close();
    });

    test('a declined offer fails on the sending phone', () async {
      final sending = sender();
      final receiving = receiver();
      final requested = watched(sending.offer(await offerAll()));
      await receiving.offer();
      await receiving.decline();
      await expectLater(requested, throwsA(isA<PairingDeclinedException>()));
    });

    test('a file that does not match the plan installs nothing', () async {
      receiverPacks.plans['de'] = PairingPlan.available([
        PairingFile(
          name: 'de-en/model.bin',
          size: 150000,
          sha256: sha256Of(bytesOf(150000, 9)),
        ),
        PairingFile(
          name: 'de-en/vocab.spm',
          size: 1000,
          sha1: sha1Of(german['de-en/vocab.spm']!),
        ),
      ]);
      receiverPacks.plans['fr'] = PairingPlan.available([
        PairingFile(
          name: 'fr-en/model.bin',
          size: 500,
          sha1: sha1Of(bytesOf(500, 2)),
        ),
      ]);
      final sending = sender();
      final receiving = receiver();
      final requested = sending.offer(await offerAll());
      await receiving.offer();
      final received = receiving.accept({
        'translation:de',
        'translation:fr',
      }, mode: BackupRestoreMode.merge);
      final sent = await sending.send(await requested);
      expect(sent, const [
        PairingItemResult('translation:de', PairingItemOutcome.damaged),
        PairingItemResult('translation:fr', PairingItemOutcome.damaged),
      ]);
      expect(await received, sent);
      expect(receiverPacks.installs, isEmpty);
    });

    test('reports what the receiving phone could not install', () async {
      receiverPacks.outcome = PairingItemOutcome.noSpace;
      final sending = sender();
      final receiving = receiver();
      final requested = sending.offer(await offerAll());
      await receiving.offer();
      final received = receiving.accept({
        'translation:de',
      }, mode: BackupRestoreMode.merge);
      expect(await sending.send(await requested), const [
        PairingItemResult('translation:de', PairingItemOutcome.noSpace),
      ]);
      await received;
    });

    test('a file that cannot be written fails its item', () async {
      // The item's folder cannot be created: a file is in the way.
      Directory('${temp.path}/work').createSync();
      File('${temp.path}/work/0').writeAsStringSync('in the way');
      final sending = sender();
      final receiving = receiver();
      final requested = sending.offer(await offerAll());
      await receiving.offer();
      final received = receiving.accept({
        'translation:de',
        'translation:fr',
      }, mode: BackupRestoreMode.merge);
      expect(await sending.send(await requested), const [
        PairingItemResult('translation:de', PairingItemOutcome.failed),
      ]);
      await received;
    });

    test('the receiver can stop the transfer', () async {
      final sending = sender();
      final receiving = receiver();
      final requested = sending.offer(await offerAll());
      await receiving.offer();
      final received = watched(
        receiving.accept({'translation:de'}, mode: BackupRestoreMode.merge),
      );
      final wanted = await requested;
      var cancelled = false;
      final sent = sending.send(
        wanted,
        onProgress: (_) {
          if (cancelled) return;
          cancelled = true;
          unawaited(receiving.cancel());
        },
      );
      await expectLater(sent, throwsA(isA<PairingException>()));
      await expectLater(received, throwsA(isA<PairingException>()));
      expect(Directory('${temp.path}/work').existsSync(), isFalse);
    });

    test('the sender can stop the transfer', () async {
      final sending = sender();
      final receiving = receiver();
      final requested = sending.offer(await offerAll());
      await receiving.offer();
      final received = watched(
        receiving.accept({'translation:de'}, mode: BackupRestoreMode.merge),
      );
      final wanted = await requested;
      final sent = watched(sending.send(wanted));
      await sending.cancel();
      await expectLater(sent, throwsA(isA<PairingException>()));
      await expectLater(received, throwsA(isA<PairingException>()));
    });

    test('a file that changed after the offer stops the transfer', () async {
      final sending = sender();
      final receiving = receiver();
      final outgoing = await offerAll();
      final requested = sending.offer(outgoing);
      await receiving.offer();
      final received = watched(
        receiving.accept({'data:backup'}, mode: BackupRestoreMode.merge),
      );
      final wanted = await requested;
      final shrunk = PairingRequestedItem(
        PairingOutgoingItem(wanted.single.item, {
          'backup.json': () => Stream.value([1, 2]),
        }),
        wanted.single.files,
      );
      await expectLater(
        sending.send([shrunk]),
        throwsA(isA<PairingProtocolException>()),
      );
      await expectLater(received, throwsA(isA<PairingCancelledException>()));
    });

    test('a file that grew after the offer stops the transfer', () async {
      final sending = sender();
      final receiving = receiver();
      final requested = sending.offer(await offerAll());
      await receiving.offer();
      final received = watched(
        receiving.accept({'data:backup'}, mode: BackupRestoreMode.merge),
      );
      final wanted = await requested;
      final grown = PairingRequestedItem(
        PairingOutgoingItem(wanted.single.item, {
          'backup.json': () => Stream.value(List.filled(1 << 20, 32)),
        }),
        wanted.single.files,
      );
      await expectLater(
        sending.send([grown]),
        throwsA(isA<PairingProtocolException>()),
      );
      await expectLater(received, throwsA(isA<PairingException>()));
    });

    test('the receiver times out waiting for an offer', () async {
      final receiving = receiver(
        timeouts: const PairingTimeouts(decision: Duration(milliseconds: 20)),
      );
      await expectLater(
        receiving.offer(),
        throwsA(isA<PairingTimeoutException>()),
      );
      await receiving.close();
    });
  });

  group('the sending phone refuses answers', () {
    Future<Object?> answer(Map<String, Object?> fields) async {
      final sending = sender();
      final requested = sending.offer(await offerAll());
      await receiverChannel.receiveMessage(timeout: const Duration(seconds: 5));
      await receiverChannel.send('accept', fields);
      try {
        await requested;
        return null;
      } on Object catch (error) {
        return error;
      }
    }

    test('that are not a list', () async {
      expect(await answer({'items': 'all'}), isA<PairingProtocolException>());
    });

    test('with malformed entries', () async {
      expect(
        await answer({
          'items': [
            {'id': 1},
          ],
        }),
        isA<PairingProtocolException>(),
      );
    });

    test('for items it did not offer', () async {
      expect(
        await answer({
          'items': [
            {'id': 'translation:ja', 'files': <Object?>[]},
          ],
        }),
        isA<PairingProtocolException>(),
      );
    });

    test('for the same item twice', () async {
      final entry = {
        'id': 'translation:fr',
        'files': ['fr-en/model.bin'],
      };
      expect(
        await answer({
          'items': [entry, entry],
        }),
        isA<PairingProtocolException>(),
      );
    });

    test('for files it did not offer', () async {
      expect(
        await answer({
          'items': [
            {
              'id': 'translation:fr',
              'files': ['../../shared_prefs.xml'],
            },
          ],
        }),
        isA<PairingProtocolException>(),
      );
      expect(
        await answer({
          'items': [
            {
              'id': 'translation:fr',
              'files': ['fr-en/model.bin', 'fr-en/model.bin'],
            },
          ],
        }),
        isA<PairingProtocolException>(),
      );
    });

    test('with an invalid result', () async {
      final sending = sender();
      final requested = sending.offer(await offerAll());
      await receiverChannel.receiveMessage(timeout: const Duration(seconds: 5));
      await receiverChannel.send('accept', {
        'items': [
          {
            'id': 'translation:fr',
            'files': ['fr-en/model.bin'],
          },
        ],
      });
      final sent = sending.send(await requested);
      await receiverChannel.receiveMessage(timeout: const Duration(seconds: 5));
      await receiverChannel.receive(timeout: const Duration(seconds: 5));
      await receiverChannel.send('result', {
        'item': 'translation:fr',
        'status': 'great',
      });
      await expectLater(sent, throwsA(isA<PairingProtocolException>()));
    });
  });

  group('the receiving phone refuses offers', () {
    Future<Object?> offer(Map<String, Object?> fields) async {
      await senderChannel.send('offer', fields);
      try {
        await receiver().offer();
        return null;
      } on Object catch (error) {
        return error;
      }
    }

    final item = const PairingItem(
      kind: PairingItemKind.ocr,
      key: 'deu',
      files: [PairingFile(name: 'deu.traineddata', size: 3)],
    ).toJson();

    test('that are not a list', () async {
      expect(await offer({'items': 3}), isA<PairingProtocolException>());
    });

    test('with too many items', () async {
      expect(
        await offer({
          'items': List.filled(PairingReceiver.maxItems + 1, const {
            'kind': 'ocr',
            'key': 'a',
            'files': <Object?>[],
          }),
        }),
        isA<PairingProtocolException>(),
      );
    });

    test('with the same item twice', () async {
      expect(
        await offer({
          'items': [item, item],
        }),
        isA<PairingProtocolException>(),
      );
    });

    test('with an invalid item', () async {
      expect(
        await offer({
          'items': [
            {'kind': 'apps', 'key': 'x', 'files': <Object?>[]},
          ],
        }),
        isA<PairingProtocolException>(),
      );
    });

    test('for kinds it has no packs for', () async {
      await senderChannel.send('offer', {
        'items': [item],
      });
      final offered = await receiver().offer();
      expect(offered.single.plan, const PairingPlan.incompatible());
    });
  });

  group('the receiving phone refuses files', () {
    late PairingReceiver receiving;
    late Future<List<PairingItemResult>> received;

    setUp(() async {
      receiverPacks.plans.remove('fr');
      receiving = receiver();
      await senderChannel.send('offer', {
        'items': [senderPacks.item('fr').toJson()],
      });
      await receiving.offer();
      received = watched(
        receiving.accept({'translation:fr'}, mode: BackupRestoreMode.merge),
      );
      // Wait for the request.
      await senderChannel.receiveMessage(timeout: const Duration(seconds: 5));
    });

    test('it did not ask for', () async {
      await senderChannel.send('file', {
        'item': 'translation:fr',
        'name': 'fr-en/other.bin',
        'size': 500,
      });
      await expectLater(received, throwsA(isA<PairingProtocolException>()));
    });

    test('longer than announced', () async {
      await senderChannel.send('file', {
        'item': 'translation:fr',
        'name': 'fr-en/model.bin',
        'size': 500,
      });
      await senderChannel.sendData(bytesOf(501));
      await expectLater(received, throwsA(isA<PairingProtocolException>()));
    });

    test('interrupted by another message', () async {
      await senderChannel.send('file', {
        'item': 'translation:fr',
        'name': 'fr-en/model.bin',
        'size': 500,
      });
      await senderChannel.send('done');
      await expectLater(received, throwsA(isA<PairingProtocolException>()));
    });

    test('interrupted by a cancel', () async {
      await senderChannel.send('file', {
        'item': 'translation:fr',
        'name': 'fr-en/model.bin',
        'size': 500,
      });
      await senderChannel.send('cancel');
      await expectLater(received, throwsA(isA<PairingCancelledException>()));
    });
  });

  group('PairingLibrary', () {
    test('lists every kind, leaving out kinds that fail', () async {
      final library = PairingLibrary(
        packs: [
          senderPacks,
          FakePacks(kind: PairingItemKind.ocr, failOutgoing: true),
        ],
      );
      expect(library.packs.keys, [
        PairingItemKind.translation,
        PairingItemKind.ocr,
      ]);
      expect(await library.outgoingPacks(), hasLength(3));
    });

    test('cannot take data or kinds it has nothing for', () async {
      final library = PairingLibrary();
      final data = (await offerAll()).first.item;
      expect(await library.plan(data), const PairingPlan.incompatible());
      expect(
        await library.plan(senderPacks.item('fr')),
        const PairingPlan.incompatible(),
      );
      expect(
        await library.install(data, const [], mode: BackupRestoreMode.merge),
        PairingItemOutcome.incompatible,
      );
      expect(
        await library.install(
          senderPacks.item('fr'),
          const [],
          mode: BackupRestoreMode.merge,
        ),
        PairingItemOutcome.incompatible,
      );
    });

    test('plans that fail make an item incompatible', () async {
      final library = PairingLibrary(packs: [_ThrowingPacks()]);
      expect(
        await library.plan(senderPacks.item('fr')),
        const PairingPlan.incompatible(),
      );
      expect(
        await library.install(
          senderPacks.item('fr'),
          const [],
          mode: BackupRestoreMode.merge,
        ),
        PairingItemOutcome.noSpace,
      );
    });
  });

  group('PairingBackupItem', () {
    PairingItem dataItem(int size, {String name = 'backup.json'}) =>
        PairingItem(
          kind: PairingItemKind.data,
          key: 'backup',
          files: [PairingFile(name: name, size: size)],
        );

    test('takes one backup file of a sane size', () {
      expect(
        PairingBackupItem.plan(dataItem(10)),
        const PairingPlan.available([
          PairingFile(name: 'backup.json', size: 10),
        ]),
      );
      expect(
        PairingBackupItem.plan(dataItem(PairingBackupItem.maxSize + 1)),
        const PairingPlan.incompatible(),
      );
      expect(
        PairingBackupItem.plan(dataItem(10, name: 'other.json')),
        const PairingPlan.incompatible(),
      );
    });

    Future<PairingItemOutcome> restore(String contents) async {
      final file = File('${temp.path}/backup.json')
        ..writeAsStringSync(contents);
      return await PairingBackupItem.restore(
        receiverBackup,
        file,
        mode: BackupRestoreMode.replace,
      );
    }

    test('refuses what is not a backup', () async {
      expect(await restore('[1]'), PairingItemOutcome.damaged);
      expect(await restore('{"format": "zip"}'), PairingItemOutcome.damaged);
      expect(await restore('{'), PairingItemOutcome.damaged);
      final file = File('${temp.path}/bad.json')
        ..writeAsBytesSync([0xff, 0xfe, 0xfd]);
      expect(
        await PairingBackupItem.restore(
          receiverBackup,
          file,
          mode: BackupRestoreMode.replace,
        ),
        PairingItemOutcome.damaged,
      );
    });

    test('refuses a backup from a newer version', () async {
      expect(
        await restore(
          '{"format":"mozhi-backup","formatVersion":99,'
          '"createdAt":"2026-10-22T00:00:00Z","appVersion":"9",'
          '"sections":{}}',
        ),
        PairingItemOutcome.incompatible,
      );
    });

    test('reports a section that fails', () async {
      final registry = BackupRegistry(appVersion: () async => '1')
        ..register(_FailingSection());
      final snapshot = await senderBackup.snapshot(includeSecrets: false);
      final file = File('${temp.path}/backup.json')
        ..writeAsBytesSync(
          PairingBackupItem.snapshotBytes(
            BackupSnapshot(
              createdAt: snapshot.createdAt,
              appVersion: snapshot.appVersion,
              sections: {'history': snapshot.sections['history']!},
            ),
          ),
        );
      expect(
        await PairingBackupItem.restore(
          registry,
          file,
          mode: BackupRestoreMode.merge,
        ),
        PairingItemOutcome.noSpace,
      );
    });
  });

  group('pairingOutcomeOf', () {
    test('tells a full disk from other failures', () {
      const full = FileSystemException('full', 'x', OSError('No space', 28));
      expect(pairingOutcomeOf(full), PairingItemOutcome.noSpace);
      expect(
        pairingOutcomeOf(const BackupSectionException('history', full)),
        PairingItemOutcome.noSpace,
      );
      expect(
        pairingOutcomeOf(const FileSystemException('denied')),
        PairingItemOutcome.failed,
      );
      expect(pairingOutcomeOf(StateError('x')), PairingItemOutcome.failed);
    });
  });
}

class _ThrowingPacks implements PairingPacks {
  @override
  PairingItemKind get kind => PairingItemKind.translation;

  @override
  Future<List<PairingOutgoingItem>> outgoing() => throw StateError('x');

  @override
  Future<PairingPlan> plan(PairingItem item) => throw StateError('x');

  @override
  Future<PairingItemOutcome> install(PairingItem item, List<File> files) =>
      throw const FileSystemException('full', 'x', OSError('No space', 28));
}

class _FailingSection implements BackupSection {
  @override
  String get id => 'history';

  @override
  int get version => 1;

  @override
  Future<Object?> export({required bool includeSecrets}) async => null;

  @override
  Future<void> restore(
    Object? data, {
    required int version,
    required BackupRestoreMode mode,
  }) => throw const FileSystemException('full', 'x', OSError('No space', 28));
}
