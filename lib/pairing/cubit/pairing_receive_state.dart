import 'package:equatable/equatable.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';

/// Where **Receive on this phone** is.
enum PairingReceiveStep {
  /// Finding this phone's address and starting to listen.
  starting,

  /// This phone is on no Wi-Fi or hotspot.
  noNetwork,

  /// Showing the code until a phone connects.
  waiting,

  /// The code expired; a new one can be made.
  expired,

  /// A phone connected; both show the numbers while it chooses what to
  /// send.
  connected,

  /// The other phone's offer: the user picks what to take and accepts.
  offer,

  /// Receiving and installing.
  transferring,

  /// Finished: [PairingReceiveState.results] says what became of each
  /// item.
  done,

  /// The user said no to the offer.
  declined,

  /// Stopped: [PairingReceiveState.failure] says why.
  failed,
}

class PairingReceiveState extends Equatable {
  const new({
    this.step = PairingReceiveStep.starting,
    this.addresses = const [],
    this.address,
    this.code,
    this.expiresAt,
    this.sas,
    this.offered = const [],
    this.selected = const {},
    this.mode = BackupRestoreMode.merge,
    this.progress,
    this.results = const [],
    this.failure,
  });

  final PairingReceiveStep step;

  /// This phone's private addresses, and the one listened on.
  final List<String> addresses;
  final String? address;

  /// The code to show, and when it stops working.
  final PairingCode? code;
  final DateTime? expiresAt;

  /// The short authentication string of the connection.
  final String? sas;

  /// What the other phone offers, with what this phone makes of it.
  final List<PairingOfferedItem> offered;

  /// Ids of the offered items to take.
  final Set<String> selected;

  /// How a data item is restored.
  final BackupRestoreMode mode;

  final PairingProgress? progress;
  final List<PairingItemResult> results;
  final PairingFailure? failure;

  /// The offered items this phone can take.
  List<PairingOfferedItem> get available => [
    for (final offered in offered)
      if (offered.plan.status == PairingItemStatus.available) offered,
  ];

  /// Bytes of the selected items.
  int get selectedBytes => [
    for (final offered in available)
      if (selected.contains(offered.item.id)) offered.plan.size,
  ].fold(0, (sum, size) => sum + size);

  /// The offered data item, when there is one.
  PairingOfferedItem? get dataItem {
    for (final offered in offered) {
      if (offered.item.kind == PairingItemKind.data) return offered;
    }
    return null;
  }

  PairingReceiveState copyWith({
    PairingReceiveStep? step,
    List<String>? addresses,
    String? address,
    PairingCode? code,
    DateTime? expiresAt,
    String? sas,
    List<PairingOfferedItem>? offered,
    Set<String>? selected,
    BackupRestoreMode? mode,
    PairingProgress? progress,
    List<PairingItemResult>? results,
    PairingFailure? failure,
  }) => PairingReceiveState(
    step: step ?? this.step,
    addresses: addresses ?? this.addresses,
    address: address ?? this.address,
    code: code ?? this.code,
    expiresAt: expiresAt ?? this.expiresAt,
    sas: sas ?? this.sas,
    offered: offered ?? this.offered,
    selected: selected ?? this.selected,
    mode: mode ?? this.mode,
    progress: progress ?? this.progress,
    results: results ?? this.results,
    failure: failure ?? this.failure,
  );

  @override
  List<Object?> get props => [
    step,
    addresses,
    address,
    code,
    expiresAt,
    sas,
    offered,
    selected,
    mode,
    progress,
    results,
    failure,
  ];
}
