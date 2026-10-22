import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';

const _destination = EgressDestination(
  kind: EgressDestinationKind.cloudProvider,
  host: 'api.openai.com',
  name: 'OpenAI',
);

EgressEntry _begin(EgressLedger ledger) => ledger.begin(
  method: 'POST',
  scheme: 'https',
  destination: _destination,
  purpose: EgressPurpose.aiModel,
  bytesSent: 12,
);

void main() {
  tearDown(() => IsolateNameServer.removePortNameMapping(EgressRelay.portName));

  test('finished entries of a window reach the main window', () async {
    final main = EgressLedger();
    final quick = EgressLedger();
    final stopReceiving = EgressRelay.receive(main);
    addTearDown(stopReceiving);

    final done = _begin(quick);
    quick.update(done.copyWith(outcome: EgressOutcome.succeeded));
    final stopForwarding = EgressRelay.forward(quick);
    final pending = _begin(quick);
    await pumpEventQueue();

    // The pending one waits until it is finished.
    expect(main.entries, hasLength(1));
    expect(main.entries.single.destination, _destination);
    expect(main.entries.single.outcome, EgressOutcome.succeeded);

    quick
      ..update(pending.copyWith(outcome: EgressOutcome.failed))
      // Sent once only.
      ..update(pending.copyWith(outcome: EgressOutcome.failed));
    await pumpEventQueue();
    expect(main.entries, hasLength(2));
    expect(main.entries.last.outcome, EgressOutcome.failed);

    stopForwarding();
    final late = _begin(quick);
    quick.update(late.copyWith(outcome: EgressOutcome.succeeded));
    await pumpEventQueue();
    expect(main.entries, hasLength(2));
  });

  test('a newer main window takes over; stopping unregisters', () async {
    final first = EgressLedger();
    final second = EgressLedger();
    final stopFirst = EgressRelay.receive(first);
    final stopSecond = EgressRelay.receive(second);

    // The first one's stop leaves the second registered.
    stopFirst();
    expect(IsolateNameServer.lookupPortByName(EgressRelay.portName), isNotNull);

    final quick = EgressLedger();
    final stopForwarding = EgressRelay.forward(quick);
    addTearDown(stopForwarding);
    final entry = _begin(quick);
    quick.update(entry.copyWith(outcome: EgressOutcome.succeeded));
    await pumpEventQueue();
    expect(first.entries, isEmpty);
    expect(second.entries, hasLength(1));

    stopSecond();
    expect(IsolateNameServer.lookupPortByName(EgressRelay.portName), isNull);
  });

  test('malformed messages are ignored', () async {
    final main = EgressLedger();
    final stop = EgressRelay.receive(main);
    addTearDown(stop);

    IsolateNameServer.lookupPortByName(EgressRelay.portName)!.send('hello');
    await pumpEventQueue();

    expect(main.entries, isEmpty);
  });

  test('forwarding without a main window does nothing', () {
    final quick = EgressLedger();
    final stop = EgressRelay.forward(quick);
    addTearDown(stop);
    final entry = _begin(quick);
    quick.update(entry.copyWith(outcome: EgressOutcome.succeeded));
    expect(quick.entries, hasLength(1));
  });
}
