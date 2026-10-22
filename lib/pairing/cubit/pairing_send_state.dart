import 'package:equatable/equatable.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_failure.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';

/// What **Send to another phone** was opened for: everything (Settings),
/// or the language packs (the Offline languages screen), which decides
/// what is selected at first.
enum PairingSendPurpose { everything, packs }

/// Where **Send to another phone** is.
enum PairingSendStep {
  /// Typing, pasting or opening the other phone's code.
  enterCode,

  /// Connecting to the other phone.
  connecting,

  /// Both phones show the numbers; the user confirms they match.
  confirm,

  /// Choosing what to send.
  choose,

  /// Waiting for the other phone to accept.
  waiting,

  /// Sending.
  transferring,

  /// Finished: [PairingSendState.results] says what became of each item.
  done,

  /// Stopped: [PairingSendState.failure] says why.
  failed,
}

class PairingSendState extends Equatable {
  const new({
    this.step = PairingSendStep.enterCode,
    this.input = '',
    this.invalidCode = false,
    this.sas,
    this.loading = false,
    this.packs = const [],
    this.sections = const [],
    this.chosenSections = const {},
    this.selected = const {},
    this.includeSecrets = false,
    this.progress,
    this.results = const [],
    this.skipped = const [],
    this.failure,
  });

  final PairingSendStep step;

  /// The code as typed.
  final String input;

  /// Whether [input] was tried and is not a code.
  final bool invalidCode;

  /// The short authentication string of the connection.
  final String? sas;

  /// Whether the items to choose from are being listed.
  final bool loading;

  /// The offline items this phone can send.
  final List<PairingOutgoingItem> packs;

  /// The backup sections this phone can send, and those chosen.
  final List<String> sections;
  final Set<String> chosenSections;

  /// Ids of the items to send ([PairingBackupItem.id] for the data).
  final Set<String> selected;

  /// Whether the data includes API keys and passwords.
  final bool includeSecrets;

  final PairingProgress? progress;
  final List<PairingItemResult> results;

  /// Ids of offered items the other phone did not ask for (it has them
  /// already, or cannot use them).
  final List<String> skipped;

  final PairingFailure? failure;

  /// Whether the data is selected with at least one section.
  bool get sendsData =>
      selected.contains(PairingBackupItem.id) && chosenSections.isNotEmpty;

  /// Whether anything is selected to send.
  bool get canSend =>
      sendsData || packs.any((outgoing) => selected.contains(outgoing.item.id));

  PairingSendState copyWith({
    PairingSendStep? step,
    String? input,
    bool? invalidCode,
    String? sas,
    bool? loading,
    List<PairingOutgoingItem>? packs,
    List<String>? sections,
    Set<String>? chosenSections,
    Set<String>? selected,
    bool? includeSecrets,
    PairingProgress? progress,
    List<PairingItemResult>? results,
    List<String>? skipped,
    PairingFailure? failure,
  }) => PairingSendState(
    step: step ?? this.step,
    input: input ?? this.input,
    invalidCode: invalidCode ?? this.invalidCode,
    sas: sas ?? this.sas,
    loading: loading ?? this.loading,
    packs: packs ?? this.packs,
    sections: sections ?? this.sections,
    chosenSections: chosenSections ?? this.chosenSections,
    selected: selected ?? this.selected,
    includeSecrets: includeSecrets ?? this.includeSecrets,
    progress: progress ?? this.progress,
    results: results ?? this.results,
    skipped: skipped ?? this.skipped,
    failure: failure ?? this.failure,
  );

  @override
  List<Object?> get props => [
    step,
    input,
    invalidCode,
    sas,
    loading,
    [for (final outgoing in packs) outgoing.item],
    sections,
    chosenSections,
    selected,
    includeSecrets,
    progress,
    results,
    skipped,
    failure,
  ];
}
