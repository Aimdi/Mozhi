import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:mozhi/core/privacy/egress/egress_entry.dart';
import 'package:mozhi/core/privacy/egress/egress_ledger.dart';

/// See `EgressRelay.receive`.
void Function() receiveEgress(EgressLedger ledger, String portName) {
  final port = ReceivePort();
  // A previous main window of this process may have died without
  // unregistering: the newest one receives.
  IsolateNameServer.removePortNameMapping(portName);
  IsolateNameServer.registerPortWithName(port.sendPort, portName);
  final subscription = port.listen((message) {
    final entry = EgressEntry.fromMap(message);
    if (entry != null) ledger.add(entry);
  });
  return () {
    unawaited(subscription.cancel());
    port.close();
    if (IsolateNameServer.lookupPortByName(portName) == port.sendPort) {
      IsolateNameServer.removePortNameMapping(portName);
    }
  };
}

/// See `EgressRelay.forward`.
void Function() forwardEgress(EgressLedger ledger, String portName) {
  final sent = <int>{};
  void send() {
    for (final entry in ledger.entries) {
      if (entry.isPending || !sent.add(entry.id)) continue;
      IsolateNameServer.lookupPortByName(portName)?.send(entry.toMap());
    }
  }

  send();
  final subscription = ledger.changes.listen((_) => send());
  return () => unawaited(subscription.cancel());
}
