import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/cubit/pairing_send_cubit.dart';
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
  late PairingListener listener;
  late FakePacks senderPacks;
  late FakePacks receiverPacks;
  late BackupRegistry senderBackup;
  late BackupRegistry receiverBackup;
  late FakeSection receiverHistory;
  late TestPairingEnvironment environment;
  final cubits = <PairingSendCubit>[];
  final channels = <PairingChannel>[];

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('mozhi_pairing_send_');
    listener = await PairingListener.bind(
      InternetAddress.loopbackIPv4,
      policy: loopbackPolicy,
    );
    senderPacks = FakePacks(
      contents: {
        'de': {'de-en/model.bin': bytesOf(3000, 3)},
        'fr': {'fr-en/model.bin': bytesOf(10, 5)},
      },
    );
    receiverPacks = FakePacks(
      plans: {'fr': const PairingPlan.installed(language: 'fr')},
    );
    senderBackup = BackupRegistry(appVersion: () async => '1')
      ..register(FakeSection('history', ['hola']))
      ..register(FakeSection('settings', {'theme': 'dark'}));
    receiverHistory = FakeSection('history', ['mine']);
    receiverBackup = BackupRegistry(appVersion: () async => '1')
      ..register(receiverHistory)
      ..register(FakeSection('settings', null));
    environment = TestPairingEnvironment(
      temp,
      library: PairingLibrary(backup: senderBackup, packs: [senderPacks]),
    );
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
    await listener.close();
    await environment.dispose();
    temp.deleteSync(recursive: true);
  });

  PairingSendCubit build({
    String? initialCode,
    PairingSendPurpose purpose = PairingSendPurpose.everything,
  }) {
    final cubit = PairingSendCubit(
      environment.environment,
      initialCode: initialCode,
      purpose: purpose,
    );
    cubits.add(cubit);
    return cubit;
  }

  /// The receiving phone of the test.
  Future<PairingReceiver> receiver() async {
    final channel = await listener.connection;
    channels.add(channel);
    return PairingReceiver(
      channel,
      PairingLibrary(backup: receiverBackup, packs: [receiverPacks]),
      workDirectory: Directory('${temp.path}/in'),
    );
  }

  Future<PairingSendCubit> connected({
    PairingSendPurpose purpose = PairingSendPurpose.everything,
  }) async {
    final cubit = build(
      initialCode: ' ${listener.code.text} ',
      purpose: purpose,
    );
    expect(cubit.state.input, listener.code.text);
    await cubit.connect();
    expect(cubit.state.step, PairingSendStep.confirm);
    return cubit;
  }

  group('PairingSendCubit', () {
    test('refuses what is not a code', () async {
      final cubit = build()..setInput('hello');
      await cubit.connect();
      expect(cubit.state.step, PairingSendStep.enterCode);
      expect(cubit.state.invalidCode, isTrue);
      cubit.setInput('hello!');
      expect(cubit.state.invalidCode, isFalse);
    });

    test('connects, compares, chooses and sends', () async {
      final cubit = await connected();
      final receiving = await receiver();
      expect(cubit.state.sas, receiving.sas);

      await cubit.confirm(match: true);
      final choosing = cubit.state;
      expect(choosing.step, PairingSendStep.choose);
      expect(choosing.loading, isFalse);
      expect(choosing.packs.map((o) => o.item.id), [
        'translation:de',
        'translation:fr',
      ]);
      expect(choosing.sections, ['history', 'settings']);
      expect(choosing.chosenSections, {'history', 'settings'});
      expect(choosing.selected, {PairingBackupItem.id});
      expect(choosing.sendsData, isTrue);

      cubit
        ..toggleSection('settings')
        ..toggleSection('settings')
        ..toggleSection('settings')
        ..setIncludeSecrets(include: true)
        ..toggle('translation:de')
        ..toggle('translation:fr');
      expect(cubit.state.chosenSections, {'history'});
      expect(cubit.state.includeSecrets, isTrue);
      expect(cubit.state.canSend, isTrue);

      final sending = cubit.send();
      expect(cubit.state.step, PairingSendStep.waiting);
      final offered = await receiving.offer();
      expect(offered.first.item.sections, ['history']);
      expect(offered.first.item.secrets, isTrue);
      final received = await receiving.accept({
        for (final o in offered) o.item.id,
      }, mode: BackupRestoreMode.merge);
      await sending;
      expect(cubit.state.step, PairingSendStep.done);
      expect(cubit.state.results, received);
      expect(cubit.state.results.map((r) => r.id), [
        PairingBackupItem.id,
        'translation:de',
      ]);
      expect(cubit.state.skipped, ['translation:fr']);
      expect(cubit.state.progress?.installing, isTrue);
      expect(receiverHistory.data, {
        'value': ['hola'],
        'secret': 'key',
      });
      expect(environment.screen, [true, false]);
    });

    test('for the language packs, selects them', () async {
      final cubit = await connected(purpose: PairingSendPurpose.packs);
      await receiver();
      await cubit.confirm(match: true);
      expect(cubit.state.selected, {'translation:de', 'translation:fr'});
      expect(cubit.state.sendsData, isFalse);
    });

    test('numbers that differ stop everything', () async {
      final cubit = await connected();
      final receiving = await receiver();
      final offer = expectLater(
        receiving.offer(),
        throwsA(isA<PairingCancelledException>()),
      );
      await cubit.confirm(match: false);
      expect(cubit.state.step, PairingSendStep.failed);
      expect(cubit.state.failure, PairingFailure.sasMismatch);
      await offer;
      cubit.retry();
      expect(cubit.state.step, PairingSendStep.enterCode);
      expect(cubit.state.input, listener.code.text);
    });

    test('the other phone saying no is reported', () async {
      final cubit = await connected();
      final receiving = await receiver();
      await cubit.confirm(match: true);
      final sending = cubit.send();
      await receiving.offer();
      await receiving.decline();
      await sending;
      expect(cubit.state.failure, PairingFailure.declined);
    });

    test('a broken connection during the transfer is reported', () async {
      final cubit = await connected();
      final receiving = await receiver();
      await cubit.confirm(match: true);
      final sending = cubit.send();
      await receiving.offer();
      await receiving.cancel();
      await sending;
      expect(cubit.state.step, PairingSendStep.failed);
      expect(
        cubit.state.failure,
        anyOf(PairingFailure.cancelled, PairingFailure.connectionLost),
      );
    });

    test('nothing selected sends nothing', () async {
      final cubit = await connected();
      await receiver();
      await cubit.confirm(match: true);
      cubit.toggle(PairingBackupItem.id);
      expect(cubit.state.canSend, isFalse);
      await cubit.send();
      expect(cubit.state.step, PairingSendStep.choose);
    });

    test('data without sections is not sent', () async {
      final cubit = await connected();
      await receiver();
      await cubit.confirm(match: true);
      cubit
        ..toggleSection('history')
        ..toggleSection('settings');
      expect(cubit.state.sendsData, isFalse);
      expect(cubit.state.canSend, isFalse);
    });

    test('closing during the transfer tells the other phone', () async {
      final cubit = await connected();
      final receiving = await receiver();
      await cubit.confirm(match: true);
      unawaited(cubit.send());
      await receiving.offer();
      final accepted = expectLater(
        receiving.accept({PairingBackupItem.id}, mode: BackupRestoreMode.merge),
        throwsA(isA<PairingException>()),
      );
      await cubit.close();
      await accepted;
    });

    test('closing while connecting hangs up', () async {
      final cubit = build(initialCode: listener.code.text);
      final connecting = cubit.connect();
      await cubit.close();
      await connecting;
      final channel = await listener.connection;
      channels.add(channel);
      await expectLater(
        channel.receive(timeout: const Duration(seconds: 5)),
        throwsA(isA<PairingClosedException>()),
      );
    });

    test('reports a phone that cannot be reached', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final cubit = build(
        initialCode: PairingCode(
          address: const [127, 0, 0, 1],
          port: port,
          secret: List.filled(8, 1),
        ).text,
      );
      await cubit.connect();
      expect(cubit.state.failure, PairingFailure.unreachable);
    });

    test('reports a phone that does not take the code', () async {
      final cubit = build(
        initialCode: PairingCode(
          address: listener.code.address,
          port: listener.code.port,
          secret: List.filled(8, 1),
        ).text,
      );
      await cubit.connect();
      expect(cubit.state.failure, PairingFailure.refused);
    });

    test('refuses codes for addresses outside the network', () async {
      final cubit = build(
        initialCode: PairingCode(
          address: const [8, 8, 8, 8],
          port: 80,
          secret: List.filled(8, 1),
        ).text,
      );
      await cubit.connect();
      expect(cubit.state.failure, PairingFailure.invalidCode);
    });

    test('ignores actions out of turn', () async {
      final cubit = build();
      await cubit.confirm(match: true);
      await cubit.send();
      cubit.retry();
      expect(cubit.state, const PairingSendState());
      final connectedCubit = await connected();
      await connectedCubit.connect();
      expect(connectedCubit.state.step, PairingSendStep.confirm);
    });
  });
}
