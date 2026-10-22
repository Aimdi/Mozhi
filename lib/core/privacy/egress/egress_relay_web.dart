import 'package:mozhi/core/privacy/egress/egress_ledger.dart';

/// Browsers have one window per app: nothing to join.
void Function() receiveEgress(EgressLedger ledger, String portName) => _none;

/// Browsers have one window per app: nothing to join.
void Function() forwardEgress(EgressLedger ledger, String portName) => _none;

void _none() {}
