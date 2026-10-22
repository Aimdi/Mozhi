import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';

const _cloud = EgressDestination(
  kind: EgressDestinationKind.cloudProvider,
  host: 'api.openai.com',
  name: 'OpenAI',
);
const _local = EgressDestination(
  kind: EgressDestinationKind.thisDevice,
  host: 'localhost',
  port: 11434,
);
const _models = EgressDestination(
  kind: EgressDestinationKind.modelHost,
  host: 'huggingface.co',
  name: 'Hugging Face',
);

void main() {
  final start = DateTime(2026, 10, 22, 9);
  late EgressLedger ledger;

  setUp(() => ledger = EgressLedger(clock: () => start));

  EgressEntry record(
    EgressDestination destination, {
    EgressPurpose purpose = EgressPurpose.aiModel,
    int sent = 100,
    int received = 1000,
  }) {
    final entry = ledger.begin(
      method: 'POST',
      scheme: 'https',
      destination: destination,
      purpose: purpose,
      bytesSent: sent,
    );
    final done = entry.copyWith(
      bytesReceived: received,
      outcome: EgressOutcome.succeeded,
    );
    ledger.update(done);
    return done;
  }

  group('NetworkActivityState', () {
    test('nothing left the device', () {
      final state = NetworkActivityState.of(ledger);
      expect(state.since, start);
      expect(state.nothingLeft, isTrue);
      expect(state.requestCount, 0);
      expect(state.entries, isEmpty);
    });

    test('a server on this device keeps it on the device', () {
      record(_local);
      final state = NetworkActivityState.of(ledger);
      expect(state.nothingLeft, isTrue);
      expect(state.onDeviceRequestCount, 1);
      expect(state.offDevice, isEmpty);
      expect(state.summaries, hasLength(1));
    });

    test('totals cover the destinations off the device', () {
      final first = record(_cloud);
      record(_cloud);
      final last = record(
        _models,
        purpose: EgressPurpose.modelDownload,
        sent: 0,
        received: 5000,
      );
      record(_local);
      final state = NetworkActivityState.of(ledger);

      expect(state.nothingLeft, isFalse);
      expect(state.requestCount, 3);
      expect(state.contentDestinationCount, 1);
      expect(state.bytesSent, 200);
      expect(state.bytesReceived, 7000);
      expect(state.entries.first.id, greaterThan(last.id));
      expect(state.entries.last, first);
    });

    test('dropped requests count as having left', () {
      ledger = EgressLedger(capacity: 1, clock: () => start);
      record(_local);
      record(_local);
      final state = NetworkActivityState.of(ledger);
      expect(state.dropped, 1);
      expect(state.nothingLeft, isFalse);
      expect(state.requestCount, 1);
    });
  });

  group('NetworkActivityCubit', () {
    blocTest<NetworkActivityCubit, NetworkActivityState>(
      'follows the ledger, one state per burst of changes',
      build: () => NetworkActivityCubit(ledger),
      act: (cubit) {
        record(_cloud);
        record(_models, purpose: EgressPurpose.modelDownload);
      },
      expect: () => [
        isA<NetworkActivityState>()
            .having((s) => s.entries, 'entries', hasLength(2))
            .having((s) => s.summaries, 'summaries', hasLength(2)),
      ],
    );

    blocTest<NetworkActivityCubit, NetworkActivityState>(
      'clear starts a new log',
      setUp: () => record(_cloud),
      build: () => NetworkActivityCubit(ledger),
      act: (cubit) => cubit.clear(),
      expect: () => [
        isA<NetworkActivityState>().having(
          (s) => s.nothingLeft,
          'nothingLeft',
          isTrue,
        ),
      ],
      verify: (_) => expect(ledger.entries, isEmpty),
    );

    test('stops following the ledger when closed', () async {
      final cubit = NetworkActivityCubit(ledger);
      await cubit.close();
      record(_cloud);
      await pumpEventQueue();
      expect(cubit.state.entries, isEmpty);
    });
  });
}
