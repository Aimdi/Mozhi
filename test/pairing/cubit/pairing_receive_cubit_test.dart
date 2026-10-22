import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/cubit/pairing_receive_cubit.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/protocol/pairing_connection.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

import '../helpers/fake_packs.dart';
import '../helpers/loopback.dart';
import '../helpers/pairing_environment.dart';

void main() {
  late Directory temp;
  late FakePacks receiverPacks;
  late FakePacks senderPacks;
  late BackupRegistry backup;
  late FakeSection history;
  final channels = <PairingChannel>[];
  final environments = <TestPairingEnvironment>[];
  final cubits = <PairingReceiveCubit>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_receive_');
    receiverPacks = FakePacks(
      plans: {'fr': const PairingPlan.installed(language: 'fr')},
    );
    senderPacks = FakePacks(
      contents: {
        'de': {'de-en/model.bin': bytesOf(3000, 3)},
        'fr': {'fr-en/model.bin': bytesOf(10, 5)},
      },
    );
    history = FakeSection('history', ['mine']);
    backup = BackupRegistry(appVersion: () async => '1')..register(history);
  });

  tearDown(() async {
    for (final cubit in cubits) {
      await cubit.close();
    }
    cubits.clear();
    for (final channel in channels) {
      channel.destroy();
    }
    channels.clear();
    for (final environment in environments) {
      await environment.dispose();
    }
    environments.clear();
    temp.deleteSync(recursive: true);
  });

  PairingReceiveCubit build({
    List<String> addresses = const ['127.0.0.1'],
    Duration codeValidity = const Duration(minutes: 1),
    Exception? bindError,
  }) {
    final environment = TestPairingEnvironment(
      temp,
      library: PairingLibrary(backup: backup, packs: [receiverPacks]),
      addresses: addresses,
      codeValidity: codeValidity,
      bindError: bindError,
    );
    environments.add(environment);
    final cubit = PairingReceiveCubit(environment.environment);
    cubits.add(cubit);
    return cubit;
  }

  Future<PairingReceiveState> until(
    PairingReceiveCubit cubit,
    bool Function(PairingReceiveState state) test,
  ) async {
    if (test(cubit.state)) return cubit.state;
    return await cubit.stream
        .firstWhere(test)
        .timeout(const Duration(seconds: 10));
  }

  Future<PairingChannel> connect(PairingCode code) async {
    final channel = await connectPairing(code, policy: loopbackPolicy);
    channels.add(channel);
    return channel;
  }

  Future<List<PairingOutgoingItem>> offer() async => [
    ...await PairingLibrary(packs: [senderPacks]).outgoingPacks(),
    PairingOutgoingItem(
      const PairingItem(
        kind: PairingItemKind.data,
        key: PairingBackupItem.key,
        files: [PairingFile(name: PairingBackupItem.fileName, size: 2)],
      ),
      {PairingBackupItem.fileName: () => Stream.value('{}'.codeUnits)},
    ),
  ];

  group('PairingReceiveCubit', () {
    test('without a network, says so', () async {
      final cubit = build(addresses: const []);
      await cubit.start();
      expect(cubit.state.step, PairingReceiveStep.noNetwork);
    });

    test('shows a code, takes an offer and receives it', () async {
      final cubit = build();
      await cubit.start();
      final waiting = cubit.state;
      expect(waiting.step, PairingReceiveStep.waiting);
      expect(waiting.address, '127.0.0.1');
      expect(waiting.addresses, ['127.0.0.1']);
      expect(waiting.code?.host, '127.0.0.1');
      expect(waiting.expiresAt, isNotNull);

      final channel = await connect(waiting.code!);
      final connected = await until(
        cubit,
        (s) => s.step == PairingReceiveStep.connected,
      );
      expect(connected.sas, channel.sas);

      final sender = PairingSender(channel);
      final items = await offer();
      final requested = sender.offer(items.sublist(0, 2));
      final offered = await until(
        cubit,
        (s) => s.step == PairingReceiveStep.offer,
      );
      expect(offered.offered, hasLength(2));
      expect(offered.available.map((o) => o.item.id), ['translation:de']);
      expect(offered.selected, {'translation:de'});
      expect(offered.selectedBytes, 3000);
      expect(offered.dataItem, isNull);

      cubit
        ..toggle('translation:de')
        ..toggle('translation:fr');
      expect(cubit.state.selected, isEmpty);
      cubit
        ..toggle('translation:de')
        ..setMode(BackupRestoreMode.replace);
      expect(cubit.state.mode, BackupRestoreMode.replace);

      final accepted = cubit.accept();
      expect(cubit.state.step, PairingReceiveStep.transferring);
      final results = await sender.send(await requested);
      await accepted;
      expect(cubit.state.step, PairingReceiveStep.done);
      expect(cubit.state.results, results);
      expect(cubit.state.progress?.installing, isTrue);
      expect(receiverPacks.installs.keys, ['de']);
      expect(environments.single.screen, [true, false]);
      // Nothing to accept twice.
      await cubit.accept();
      expect(cubit.state.step, PairingReceiveStep.done);
    });

    test('an offer with data selects it', () async {
      final cubit = build();
      await cubit.start();
      final channel = await connect(cubit.state.code!);
      unawaited(
        PairingSender(channel)
            .offer(await offer())
            .then((_) {}, onError: (_) {}),
      );
      final offered = await until(
        cubit,
        (s) => s.step == PairingReceiveStep.offer,
      );
      expect(offered.dataItem?.item.id, PairingBackupItem.id);
      expect(offered.selected, contains(PairingBackupItem.id));
    });

    test('declining tells the other phone', () async {
      final cubit = build();
      await cubit.start();
      final channel = await connect(cubit.state.code!);
      final requested = PairingSender(channel).offer(await offer());
      await until(cubit, (s) => s.step == PairingReceiveStep.offer);
      final refused = expectLater(
        requested,
        throwsA(isA<PairingDeclinedException>()),
      );
      await cubit.decline();
      expect(cubit.state.step, PairingReceiveStep.declined);
      await refused;
      // Nothing to decline twice.
      await cubit.decline();
    });

    test('the code expires', () async {
      final cubit = build(codeValidity: const Duration(milliseconds: 50));
      await cubit.start();
      await until(cubit, (s) => s.step == PairingReceiveStep.expired);
    });

    test('wrong codes burn the code', () async {
      final cubit = build();
      await cubit.start();
      final code = cubit.state.code!;
      final wrong = PairingCode(
        address: code.address,
        port: code.port,
        secret: List.filled(8, 9),
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(
          connectPairing(wrong, policy: loopbackPolicy),
          throwsA(isA<PairingClosedException>()),
        );
      }
      final failed = await until(
        cubit,
        (s) => s.step == PairingReceiveStep.failed,
      );
      expect(failed.failure, PairingFailure.tooManyAttempts);
    });

    test('a new code on another address replaces the old one', () async {
      final cubit = build(addresses: const ['127.0.0.1', '127.0.0.2']);
      await cubit.start();
      final first = cubit.state.code!;
      await cubit.useAddress('127.0.0.2');
      expect(cubit.state.step, PairingReceiveStep.waiting);
      expect(cubit.state.address, '127.0.0.2');
      expect(cubit.state.code, isNot(first));
      await expectLater(
        connectPairing(first, policy: loopbackPolicy),
        throwsA(isA<PairingUnreachableException>()),
      );
      // An unknown address falls back to the best one.
      await cubit.start(address: '10.9.9.9');
      expect(cubit.state.address, '127.0.0.1');
    });

    test('a failure to listen is reported', () async {
      final cubit = build(bindError: const SocketException('in use'));
      await cubit.start();
      expect(cubit.state.step, PairingReceiveStep.failed);
      expect(cubit.state.failure, PairingFailure.unknown);
    });

    test('the other phone stopping is reported', () async {
      final cubit = build();
      await cubit.start();
      final channel = await connect(cubit.state.code!);
      await until(cubit, (s) => s.step == PairingReceiveStep.connected);
      await channel.cancel();
      final failed = await until(
        cubit,
        (s) => s.step == PairingReceiveStep.failed,
      );
      expect(failed.failure, PairingFailure.cancelled);
    });

    test('a transfer that breaks is reported', () async {
      final cubit = build();
      await cubit.start();
      final channel = await connect(cubit.state.code!);
      final sender = PairingSender(channel);
      final requested = sender.offer(await offer());
      await until(cubit, (s) => s.step == PairingReceiveStep.offer);
      final accepted = cubit.accept();
      await requested;
      channel.destroy();
      await accepted;
      expect(cubit.state.step, PairingReceiveStep.failed);
      expect(cubit.state.failure, PairingFailure.connectionLost);
      expect(environments.single.screen, [true, false]);
    });

    test('closing stops listening and any transfer', () async {
      final cubit = build();
      await cubit.start();
      final code = cubit.state.code!;
      final channel = await connect(code);
      final sender = PairingSender(channel);
      final requested = sender.offer(await offer());
      await until(cubit, (s) => s.step == PairingReceiveStep.offer);
      final accepted = cubit.accept();
      final sent = sender.send(await requested);
      unawaited(sent.then((_) {}, onError: (Object _) {}));
      await cubit.close();
      await accepted;
      await expectLater(sent, throwsA(isA<PairingException>()));
      await expectLater(
        connectPairing(code, policy: loopbackPolicy),
        throwsA(isA<PairingUnreachableException>()),
      );
    });

    test('a phone connecting after closing is turned away', () async {
      final cubit = build();
      await cubit.start();
      final code = cubit.state.code!;
      await cubit.close();
      await expectLater(
        connectPairing(code, policy: loopbackPolicy),
        throwsA(isA<PairingUnreachableException>()),
      );
      // Starting a closed cubit does nothing.
      await cubit.start();
    });

    test('toggles only available items, during the offer', () {
      final cubit = build()..toggle('translation:de');
      expect(cubit.state.selected, isEmpty);
    });
  });
}
