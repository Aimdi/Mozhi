import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:mozhi/core/privacy/egress/egress_entry.dart';
import 'package:mozhi/core/privacy/egress/egress_ledger.dart';

/// What the network activity page shows: the [EgressLedger] of this
/// session, summarised per destination.
class NetworkActivityState extends Equatable {
  const new({
    required this.since,
    this.entries = const [],
    this.summaries = const [],
    this.dropped = 0,
  });

  /// The state of [ledger] now.
  factory of(EgressLedger ledger) => NetworkActivityState(
    since: ledger.since,
    entries: ledger.entries.reversed.toList(growable: false),
    summaries: ledger.summarize(),
    dropped: ledger.dropped,
  );

  /// When the log started (the start of the session or the last clear).
  final DateTime since;

  /// Every recorded request, newest first.
  final List<EgressEntry> entries;

  /// One per destination that may have received something
  /// ([EgressLedger.summarize]).
  final List<EgressDestinationSummary> summaries;

  /// Older requests no longer listed (the log keeps the latest ones).
  final int dropped;

  /// The [summaries] of destinations off the device (all but servers on
  /// this device, whose requests stay here).
  List<EgressDestinationSummary> get offDevice => [
    for (final summary in summaries)
      if (summary.destination.kind != EgressDestinationKind.thisDevice) summary,
  ];

  /// Whether no request may have left the device since [since].
  bool get nothingLeft => dropped == 0 && offDevice.isEmpty;

  /// Requests that may have left the device (the [dropped] ones counted
  /// too).
  int get requestCount =>
      offDevice.fold(0, (sum, summary) => sum + summary.requests) + dropped;

  /// Requests to servers on this device.
  int get onDeviceRequestCount => summaries
      .where((s) => s.destination.kind == EgressDestinationKind.thisDevice)
      .fold(0, (sum, summary) => sum + summary.requests);

  /// Destinations off the device that received the user's text or a photo.
  int get contentDestinationCount =>
      offDevice.where((summary) => summary.receivedContent).length;

  /// Bytes sent off the device.
  int get bytesSent => offDevice.fold(0, (sum, s) => sum + s.bytesSent);

  /// Bytes received from off the device.
  int get bytesReceived => offDevice.fold(0, (sum, s) => sum + s.bytesReceived);

  @override
  List<Object?> get props => [since, entries, summaries, dropped];
}

/// Follows an [EgressLedger] for the network activity page; [clear] starts
/// a new log.
class NetworkActivityCubit extends Cubit<NetworkActivityState> {
  new(this._ledger) : super(NetworkActivityState.of(_ledger)) {
    _changes = _ledger.changes.listen((_) => _refresh());
  }

  final EgressLedger _ledger;
  late final StreamSubscription<void> _changes;
  var _scheduled = false;

  /// Forgets what was recorded so far.
  void clear() => _ledger.clear();

  /// Changes come in bursts (a request starts, gets its status, ends):
  /// one rebuild per burst.
  void _refresh() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!isClosed) emit(NetworkActivityState.of(_ledger));
    });
  }

  @override
  Future<void> close() async {
    await _changes.cancel();
    await super.close();
  }
}
